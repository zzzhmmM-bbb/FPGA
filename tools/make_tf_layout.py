"""Create an OPTIONAL offline raw BMP layout as a regular file; no device IO."""
import sys
sys.dont_write_bytecode=True
import datetime,json,struct,uuid
from package_common import ROOT,safe_path,sha

def make_layout():
    names=('00_cover_loudness.bmp','01_cover_tone.bmp','02_cover_vowel.bmp',
           '03_bg_loudness.bmp','04_bg_tone.bmp','05_bg_vowel.bmp')
    images=[]
    for name in names:
        path=safe_path(ROOT,'assets/tf_card/'+name);data=path.read_bytes()
        if (len(data)!=921654 or data[:2]!=b'BM' or struct.unpack_from('<ii',data,18)!=(640,480)
            or struct.unpack_from('<H',data,28)[0]!=24 or struct.unpack_from('<I',data,30)[0]!=0):
            raise ValueError('Unexpected frozen BMP: '+name)
        images.append((name,path,data))
    rel='output/tf_layout/'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8]
    out=safe_path(ROOT,rel);out.mkdir(parents=True)
    target=out/'tf_layout_candidate.img';rows=[];sector=0
    # Exclusive creation; this tool has no argument for a disk/device/path.
    with target.open('xb') as stream:
        for name,path,data in images:
            count=(len(data)+511)//512
            stream.write(data);stream.write(bytes(count*512-len(data)))
            rows.append({'name':name,'start_sector':sector,'sectors':count,'bytes':len(data),'sha256':sha(path)})
            sector+=count
    result={'status':'offline_layout_generated','hardware_verified':None,'not_an_original_card_backup':True,
            'bytes':target.stat().st_size,'sha256':sha(target),'images':rows}
    (out/'layout.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({'image':str(target),'metadata':str(out/'layout.json'),'hardware_verified':None},ensure_ascii=False))
    return result,target

if __name__=='__main__':
    try:make_layout()
    except Exception as exc:print('FAIL:',exc,file=sys.stderr);sys.exit(1)
