"""Local package utilities. Python 3.9+, standard library only."""
import hashlib
import os
import re
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
AL_PATHS = ('project/main/src/td_project/HDMI1.4b_Transmitter_v1.0.al', 'project/slave/board2.al')
BITS = {
    'bit/main/main_T10b_lv3fix.bit':'4ac4dcd1a290a70701a6b642219e6dbd241a4dbff6cdcf3cc325d10a962a0e77',
    'bit/slave/slave_v26_local.bit':'6039b3d4ba39a2d830c13a62a11afd9e5d7fd3069c2f13a2811f9a159507953c'}

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def is_link(p):
    return p.is_symlink() or bool(getattr(p.lstat(),'st_file_attributes',0) & 1024)

def safe_path(root, rel):
    """Reject traversal, Windows aliases and every existing reparse ancestor."""
    p = PurePosixPath(rel)
    if (not rel or p.is_absolute() or '\\' in rel or ':' in rel or
        p.as_posix()!=rel or any(x in ('.','..') or x.rstrip(' .')!=x for x in p.parts)):
        raise ValueError('Unsafe relative path: '+rel)
    q = root
    if is_link(q): raise ValueError('Linked root: '+str(q))
    for part in p.parts:
        q = q / part
        if q.exists() or q.is_symlink():
            if is_link(q): raise ValueError('Linked path: '+str(q))
    q.resolve().relative_to(root.resolve())
    return q

def files(root, ignore_generated=False):
    result=[]
    if is_link(root): raise ValueError('Linked root')
    for base, dirs, names in os.walk(root,followlinks=False):
        here=Path(base)
        for n in dirs+names:
            if is_link(here/n): raise ValueError('Linked entry: '+str(here/n))
        if ignore_generated and here==root:
            dirs[:]=[n for n in dirs if n!='output']
        for n in names:
            p=here/n; rel=p.relative_to(root).as_posix()
            if ignore_generated and rel=='tools/toolchain.json': continue
            result.append(p)
    return sorted(result)

def root_path_span(data):
    projects=list(re.finditer(rb'<Project\b[^>]*>',data))
    if len(projects)!=1: raise ValueError('Expected exactly one Project root tag')
    tag=projects[0]
    attrs=list(re.finditer(rb'(?<![\w:])Path="([^"]*)"',tag.group()))
    if len(attrs)!=1: raise ValueError('Expected exactly one Project Path attribute')
    a=attrs[0]
    return tag.start()+a.start(1), tag.start()+a.end(1)

def normalize_al(data):
    a,b=root_path_span(data)
    return data[:a]+b'__PROJECT_ROOT__'+data[b:]

def adapt_al(path):
    data=path.read_bytes();a,b=root_path_span(data)
    value=path.parent.resolve().as_posix()
    if any(c in value for c in '"<>\r\n'): raise ValueError('Unsupported project directory')
    updated=data[:a]+value.encode('utf-8')+data[b:]
    if updated!=data: path.write_bytes(updated)
    return updated!=data

def decode_log(data):
    if data.startswith((b'\xff\xfe',b'\xfe\xff')): return data.decode('utf-16',errors='replace')
    if data[:1000].count(b'\x00')>100: return data.decode('utf-16-le',errors='replace')
    return data.decode('utf-8',errors='replace')
