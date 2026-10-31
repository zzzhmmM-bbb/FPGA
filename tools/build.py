"""Copy into a new output directory, then invoke TD with an argument list."""
import sys
sys.dont_write_bytecode=True
import argparse, datetime, json, os, re, shutil, subprocess, uuid
from pathlib import Path
from package_common import ROOT, adapt_al, files, safe_path, sha, decode_log

def build(board, td, check_only=False):
    safe_path(ROOT,'output')
    out=ROOT/'output'/board/(datetime.datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8])
    safe_path(ROOT,out.relative_to(ROOT).as_posix());out.mkdir(parents=True)
    source=safe_path(ROOT,'project/'+board)
    original={p.relative_to(source).as_posix():sha(p) for p in files(source)}
    staged=out/'src';shutil.copytree(source,staged)
    if os.name=='nt' and any(len(str(p.resolve()))>=260 for p in files(staged)):
        raise ValueError('TD MAX_PATH=260: extract the package to a shorter directory before building; failed copy retained at '+str(out))
    al=staged/('src/td_project/HDMI1.4b_Transmitter_v1.0.al' if board=='main' else 'board2.al')
    adapt_al(al)
    rom_copies=[]
    if board=='main':
        # TD's readmem lookup starts at the calling HDL directory. Supply
        # identical frozen tables there in the build copy; never edit RTL.
        for name in ('score_packed.hex','wave_packed.hex'):
            src=al.parent/name
            dst=staged/'src/user_source/hdl_source'/name
            if not src.is_file(): raise ValueError('Missing BGM ROM: '+name)
            if dst.exists() and sha(dst)!=sha(src): raise ValueError('Conflicting BGM ROM: '+name)
            shutil.copy2(src,dst);rom_copies.append({'from':str(src),'to':str(dst),'sha256':sha(dst)})
    script=staged/'build.tcl'
    if board=='slave': shutil.copy2(safe_path(ROOT,'tools/build_slave.tcl'),script)
    if check_only and board=='main':
        data=script.read_bytes();anchor=b'# Official TD V6.2'
        if data.count(anchor)!=1: raise ValueError('Frozen main check insertion point differs')
        script.write_bytes(data.replace(anchor,b'puts "PROJECT_CHECK_PASS"\nexit\n'+anchor,1))
    token='PROJECT_CHECK_PASS' if check_only else ('VOWEL_FIXED_BUILD_COMPLETE' if board=='main' else 'SLAVE_BUILD_COMPLETE')
    bit=staged/('src/td_project/main_vowel_fixed.bit' if board=='main' else 'slave_v26_local.bit')
    if bit.exists(): raise ValueError('Pre-existing bit in clean build')
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
    temporary=out/'tmp';temporary.mkdir()
    env['TEMP']=env['TMP']=str(temporary.resolve())
    env['BUILD_CHECK_ONLY']='1' if check_only else '0'
    env['PATH']=str(Path(td).resolve().parent)+os.pathsep+env.get('PATH','')
    args=[Path(td).resolve().as_posix(),script.resolve().as_posix()]
    result={'board':board,'mode':'elaborate_only' if check_only else 'full_build',
            'argv':args,'cwd':str(al.parent),'status':'failed','inputs':original,
            'script_sha256':sha(script),'td_executable':str(Path(td).resolve()),'rom_copies':rom_copies}
    with (out/'build.raw.log').open('wb') as log:
        proc=subprocess.run(args,cwd=al.parent,env=env,stdout=log,stderr=subprocess.STDOUT)
    text=decode_log((out/'build.raw.log').read_bytes())
    (out/'build.log').write_text(text,encoding='utf-8')
    errors=bool(re.search(r'(?im)^\s*(?:#\s*)?(?:\*\*\s*)?(?:ERROR|FATAL)\b|\bERROR\s*:',text))
    missing_rom=bool(re.search(r'(?i)(?:CRITICAL-WARNING|ERROR)[^\r\n]*(?:readmem|\.hex)[^\r\n]*not found',text))
    token_ok=token in text
    bit_ok=check_only or (bit.is_file() and bit.stat().st_size>0)
    unchanged=original=={p.relative_to(source).as_posix():sha(p) for p in files(source)}
    passed=proc.returncode==0 and not errors and not missing_rom and token_ok and bit_ok and unchanged
    result.update(status='passed' if passed else 'failed',exit_code=proc.returncode,error_in_log=errors,missing_rom_in_log=missing_rom,
                  completion_token=token,completion_token_found=token_ok,expected_bit_present=bit_ok,
                  source_unchanged=unchanged,bit=None if check_only or not bit.is_file() else
                  {'path':str(bit),'bytes':bit.stat().st_size,'sha256':sha(bit)})
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({'status':result['status'],'result':str(out/'result.json'),'log':str(out/'build.log')},ensure_ascii=False))
    return result,out

def main():
    p=argparse.ArgumentParser();p.add_argument('--board',choices=('main','slave'),required=True)
    p.add_argument('--td');p.add_argument('--check-only',action='store_true');a=p.parse_args()
    td=a.td
    if not td:
        config=safe_path(ROOT,'tools/toolchain.json')
        if not config.is_file(): raise ValueError('Create tools/toolchain.json from the example, or specify --td')
        td=json.loads(config.read_text(encoding='utf-8-sig')).get('td_commands')
    if not td or not Path(td).is_file(): raise ValueError('TD executable missing: '+str(td))
    result,_=build(a.board,td,a.check_only)
    return 0 if result['status']=='passed' else 1

if __name__=='__main__':
    try: sys.exit(main())
    except Exception as exc: print('BUILD FAILED:',exc,file=sys.stderr);sys.exit(1)
