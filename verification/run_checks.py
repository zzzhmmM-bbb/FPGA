"""Dependency closure, top compilation (vendor models), TF-guard simulation."""
import sys
sys.dont_write_bytecode=True
import argparse, datetime, json, os, re, shutil, subprocess, uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from package_common import ROOT, AL_PATHS, files, safe_path, sha, decode_log

VERIF=Path(__file__).resolve().parent

def project_files(board):
    al=ROOT/AL_PATHS[0 if board=='main' else 1]
    refs=[]
    for name in re.findall(r'<File Path="([^"]+)"',al.read_text(encoding='utf-8')):
        p=(al.parent/name).resolve();rel=p.relative_to(ROOT).as_posix()
        p=safe_path(ROOT,rel)
        if not p.is_file(): raise ValueError('Missing project reference: '+rel)
        refs.append(p)
    if not refs: raise ValueError('No project references')
    return refs

def dependencies():
    """Validate every frozen textual include/readmem dependency, including parameters."""
    result={}; all_files=files(ROOT/'project')
    for board in ('main','slave'):
        refs=project_files(board); result[board]={'references':len(refs),'resolved':[]}
        base=ROOT/'project'/board
        for p in all_files:
            if not p.is_relative_to(base) or p.suffix not in ('.v','.vh','.sv'): continue
            text=p.read_text(encoding='utf-8',errors='replace')
            text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
            names=re.findall(r'`include\s+"([^"]+)"',text)
            constants=dict(re.findall(r'(?:parameter(?:\s+\w+)?|localparam(?:\s+\w+)?)\s+(\w+)\s*=\s*"([^"]+)"',text))
            for arg in re.findall(r'\$readmem[hb]\s*\(\s*([^,]+),',text):
                arg=arg.strip()
                if arg.startswith('"') and arg.endswith('"'): names.append(arg[1:-1])
                elif arg in constants: names.append(constants[arg])
                else: raise ValueError('Unresolved readmem argument '+arg+' in '+str(p))
            for name in names:
                candidates=[p.parent/name,base/name,base/'source'/name,
                            base/'src/td_project'/name,base/'src/user_source/hdl_source'/name,
                            VERIF/'assets'/name]
                hit=None
                for q in candidates:
                    try:
                        rel=q.resolve().relative_to(ROOT).as_posix();q=safe_path(ROOT,rel)
                    except ValueError: continue
                    if q.is_file(): hit=rel;break
                if not hit: raise ValueError('Missing include/ROM '+name+' referenced by '+str(p))
                result[board]['resolved'].append({'from':p.relative_to(ROOT).as_posix(),'name':name,'target':hit,'sha256':sha(ROOT/hit)})
    return result

def run_checks(iverilog=None,vvp=None):
    tb=safe_path(ROOT,'verification/tb_tf_guard.sv')
    dut=safe_path(ROOT,'project/main/src/user_source/hdl_source/thumbnail/thumbnail_mem_arbiter.v')
    if not tb.is_file() or not dut.is_file(): raise ValueError('Required TF testbench/DUT missing')
    for name in ('admission','controls','key1'):
        if not safe_path(ROOT,'verification/tb_'+name+'.sv').is_file(): raise ValueError('Required testbench missing: '+name)
    models=[safe_path(ROOT,'verification/models/'+n) for n in ('system_models.sv','hdmi_ports.v')]
    if not all(p.is_file() for p in models): raise ValueError('Required vendor models missing')
    safe_path(ROOT,'output')
    out=ROOT/'output/verification'/(datetime.datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8])
    safe_path(ROOT,out.relative_to(ROOT).as_posix());out.mkdir(parents=True)
    inputs={p.relative_to(ROOT).as_posix():sha(p) for p in files(ROOT/'project')+files(VERIF)}
    result={'status':'failed','inputs':inputs,'commands':[],'dependencies':dependencies(),'checks':{}}
    iv=iverilog or shutil.which('iverilog');vp=vvp or shutil.which('vvp')

    def command(label,args,cwd):
        proc=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,timeout=180)
        text=decode_log(proc.stdout+proc.stderr)
        (out/(label+'.log')).write_text(text,encoding='utf-8')
        row={'label':label,'argv':list(map(str,args)),'cwd':str(cwd),'exit_code':proc.returncode,'log':label+'.log'}
        result['commands'].append(row)
        return proc.returncode,text

    if not iv or not vp:
        result['checks']={k:{'status':'skipped','reason':'Icarus compiler/runtime unavailable'} for k in ('main_top','slave_top','tf_guard','admission','controls','key1')}
        result['status']='incomplete'
    else:
        command('iverilog_version',[iv,'-V'],out);command('vvp_version',[vp,'-V'],out)
        for board in ('main','slave'):
            refs=project_files(board)
            h=ROOT/'project/main/src/user_source/hdl_source'
            if board=='main':
                skip={'sys_pll','video_pll','PLL_HDMI_AUDIO','sdram','sd_card_top','hdmi_1_4b_transmitter_core_wrapper'}
                src=[p for p in refs if p.suffix=='.v' and '.enc.' not in p.name and p.stem not in skip]
                src += [h/'IP/afifo_32_16_256.v',h/'IP/afifo_16_32_256.v',*models]
                top='top';incs=[h,h/'SD',h/'thumbnail'];cwd=h
            else:
                src=[p for p in refs if p.suffix=='.v' and p.stem!='PLL_HDMI_AUDIO']
                # Only PLL models are needed by the slave.
                model=out/'slave_pll_model.sv'
                text=models[0].read_text(encoding='utf-8')
                m=re.search(r'module PLL_HDMI_AUDIO\b.*?endmodule',text,re.S)
                if not m: raise ValueError('Missing PLL model')
                model.write_text(m[0],encoding='utf-8');src.append(model)
                top='board2_top';cwd=ROOT/'project/slave';incs=[cwd,cwd/'source']
            args=[iv,'-g2012','-Wall','-DSIMULATION','-s',top,'-o',out/(board+'.vvp')]
            for inc in incs: args+=['-I',inc]
            code,text=command(board+'_top',args+src,cwd)
            result['checks'][board+'_top']={'status':'passed' if code==0 else 'failed','scope':'Full RTL top compilation with explicit vendor IP/PLL models; no physical timing validation.'}
        code,text=command('tf_compile',[iv,'-g2012','-s','tb_tf_guard','-o',out/'tf_guard.vvp',tb,dut],out)
        if code==0:
            code,text=command('tf_run',[vp,out/'tf_guard.vvp'],out)
        ok=code==0 and 'PASS_TF_TAIL_GUARD' in text and not re.search(r'(?i)\b(?:FATAL|FAIL|ERROR)\b',text)
        result['checks']['tf_guard']={'status':'passed' if ok else 'failed','required_pass_marker':'PASS_TF_TAIL_GUARD'}
        h=ROOT/'project/main/src/user_source/hdl_source'
        for name in ('admission','controls','key1'):
            bench=VERIF/('tb_'+name+'.sv');marker='PASS '+name
            code,text=command(name+'_compile',[iv,'-g2012','-s','tb_'+name,'-I',h,'-I',h/'thumbnail',
                '-y',h,'-y',h/'thumbnail','-o',out/(name+'.vvp'),bench],out)
            if code==0: code,text=command(name+'_run',[vp,out/(name+'.vvp')],out)
            ok=code==0 and marker in text and not re.search(r'(?i)\b(?:FATAL|FAIL|ERROR)\b',text)
            result['checks'][name]={'status':'passed' if ok else 'failed','required_pass_marker':marker}
        result['status']='passed' if all(x['status']=='passed' for x in result['checks'].values()) else 'failed'
    result['inputs_unchanged']=all(sha(ROOT/p)==v for p,v in inputs.items())
    if not result['inputs_unchanged']: result['status']='failed'
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({'status':result['status'],'checks':result['checks'],'result':str(out/'result.json')},ensure_ascii=False))
    return result,out

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--iverilog');p.add_argument('--vvp');a=p.parse_args()
    try:
        r,_=run_checks(a.iverilog,a.vvp);sys.exit(0 if r['status']=='passed' else 2 if r['status']=='incomplete' else 1)
    except Exception as exc: print('FAIL:',exc,file=sys.stderr);sys.exit(1)
