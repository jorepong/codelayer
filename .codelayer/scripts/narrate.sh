#!/usr/bin/env bash
# narrate.sh — learn 스킬 낭독 렌더러
#
# 한 폴더 안의 낭독 스크립트(*.script.md)를 문단 단위로 음성(mp3)으로 렌더하고,
# 학습 문서를 읽으며 그 음성을 한자리에서 제어하는 player.html을 생성한다.
# 문단마다 따로 렌더해 길이를 재므로, "몇 초에 어느 문단"이라는 큐(cue)를 만들어
# player가 재생 위치에 맞춰 문서의 해당 블록을 하이라이트한다.
#
# 사용법:
#   narrate.sh <폴더>
#
# 환경변수:
#   LEARN_TTS_ENGINE  edge(기본) | say
#     edge — Microsoft edge-tts(무료·키 불필요, 자연스러움 높음). scripts/venv-tts 필요.
#     say  — macOS 내장(오프라인, 품질 낮음). 폴백.
#   LEARN_TTS_VOICE   음성 이름. 기본: edge=ko-KR-SunHiNeural, say=Yuna.
#
# 엔진 교체 지점은 render_chunk() 하나다. 다른 클라우드/로컬 TTS로 바꾸려면 여기만 고친다.

set -euo pipefail

ENGINE="${LEARN_TTS_ENGINE:-edge}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKED="$SKILL_DIR/scripts/vendor/marked.min.js"
# TTS 환경은 스킬 코드 밖(데이터 영역)에 두어 스킬을 가볍고 이식 가능하게 유지한다. 없으면 아래에서 자동 생성.
TTS_VENV="$HOME/.claude/learn/.tts-venv"
EDGE_BIN="$TTS_VENV/bin/edge-tts"

case "$ENGINE" in
  edge) VOICE="${LEARN_TTS_VOICE:-ko-KR-SunHiNeural}" ;;
  say)  VOICE="${LEARN_TTS_VOICE:-Yuna}" ;;
  *) echo "알 수 없는 LEARN_TTS_ENGINE: $ENGINE (edge|say)" >&2; exit 1 ;;
esac

FOLDER="${1:-}"
[ -z "$FOLDER" ] && { echo "사용법: narrate.sh <폴더>" >&2; exit 1; }
[ -d "$FOLDER" ] || { echo "폴더가 없습니다: $FOLDER" >&2; exit 1; }
FOLDER="$(cd "$FOLDER" && pwd)"

command -v ffmpeg  >/dev/null || { echo "ffmpeg 필요: brew install ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe 필요(보통 ffmpeg에 포함)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 필요." >&2; exit 1; }
[ -f "$MARKED" ] || { echo "렌더러 없음: $MARKED" >&2; exit 1; }
if [ "$ENGINE" = edge ] && [ ! -x "$EDGE_BIN" ]; then
  echo "낭독 TTS(edge-tts)를 처음이라 설치합니다 → $TTS_VENV (한 번만)" >&2
  python3 -m venv "$TTS_VENV" >/dev/null 2>&1 && "$TTS_VENV/bin/pip" install -q --disable-pip-version-check edge-tts >/dev/null 2>&1 \
    || { echo "edge-tts 자동 설치 실패. 수동: python3 -m venv \"$TTS_VENV\" && \"$TTS_VENV/bin/pip\" install edge-tts  (또는 오프라인이면 LEARN_TTS_ENGINE=say)" >&2; exit 1; }
fi
if [ "$ENGINE" = say ]; then command -v say >/dev/null || { echo "say 없음(macOS 필요)" >&2; exit 1; }; fi

cd "$FOLDER"
shopt -s nullglob
scripts=( *.script.md )
[ ${#scripts[@]} -eq 0 ] && { echo "이 폴더에 *.script.md 가 없습니다: $FOLDER" >&2; exit 1; }

mkdir -p audio
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- 엔진 교체 지점: 텍스트파일 → mp3(한 문단) ---
render_chunk() {
  local infile="$1" outmp3="$2"
  if [ "$ENGINE" = edge ]; then
    "$EDGE_BIN" --voice "$VOICE" --file "$infile" --write-media "$outmp3" >/dev/null 2>&1
  else
    local aiff="$tmp/o.aiff"
    say -v "$VOICE" -o "$aiff" -f "$infile"
    ffmpeg -y -loglevel error -i "$aiff" -codec:a libmp3lame -qscale:a 4 "$outmp3"
  fi
}

for sf in "${scripts[@]}"; do
  nn="${sf%%-*}"
  cdir="$tmp/$nn"; mkdir -p "$cdir"

  # 프론트매터 제거한 본문
  awk '
    BEGIN{fm=0}
    NR==1 && /^---[[:space:]]*$/ {fm=1; next}
    fm==1 && /^---[[:space:]]*$/ {fm=2; next}
    fm!=1 {print}
  ' "$sf" > "$cdir/body.txt"

  # 본문을 문단(빈 줄 구분)으로 쪼개고, 각 문단 선두의 @태그를 떼어 기록
  #  p001.txt … (TTS로 넘길 순수 텍스트) / tags.txt (문단별 태그 한 줄씩)
  : > "$cdir/tags.txt"
  awk -v d="$cdir" '
    BEGIN{ RS=""; FS="\n"; n=0 }
    {
      para=$0; tag="p";
      if (match(para, /^@(p|fig|code|table|note|gate)[[:space:]]+/)) {
        t=substr(para,2,RLENGTH-1); sub(/[[:space:]]+$/,"",t); tag=t;
        para=substr(para, RLENGTH+1);
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",para);
      if (para=="") next;
      n++;
      print tag >> (d "/tags.txt");
      fn=sprintf("%s/p%03d.txt", d, n);
      printf "%s", para > fn; close(fn);
    }
  ' "$cdir/body.txt"

  # 문단별 렌더 → 청크 mp3, 길이 측정, 큐(start·type) 누적, concat 목록 작성
  : > "$cdir/list.txt"
  cues="["; first=1; acc="0"; k=0
  for pf in "$cdir"/p[0-9][0-9][0-9].txt; do
    k=$((k+1))
    cmp3="$cdir/c$(printf '%03d' "$k").mp3"
    render_chunk "$pf" "$cmp3"
    dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$cmp3")"
    tag="$(sed -n "${k}p" "$cdir/tags.txt")"; [ -z "$tag" ] && tag="p"
    start="$(awk -v a="$acc" 'BEGIN{printf "%.3f", a+0}')"
    [ $first -eq 1 ] && first=0 || cues="$cues,"
    cues="$cues{\"start\":$start,\"type\":\"$tag\"}"
    acc="$(awk -v a="$acc" -v dd="$dur" 'BEGIN{printf "%.6f", a+dd}')"
    echo "file '$cmp3'" >> "$cdir/list.txt"
  done
  cues="$cues]"

  if [ "$k" -eq 0 ]; then
    echo "건너뜀(문단 없음): $sf" >&2
    continue
  fi

  ffmpeg -y -loglevel error -f concat -safe 0 -i "$cdir/list.txt" -codec:a libmp3lame -qscale:a 4 "audio/$nn.mp3"
  printf '%s' "$cues" > "audio/$nn.cues.json"
  echo "렌더: $sf → audio/$nn.mp3  (문단 ${k}개, 엔진 ${ENGINE}/${VOICE})"
done

# --- player.html 생성 ---
python3 - "$FOLDER" "$MARKED" <<'PY'
import sys, os, glob, json, re, html

folder, marked_path = sys.argv[1], sys.argv[2]
os.chdir(folder)

def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def split_front_matter(text):
    m = re.match(r'^---[ \t]*\n(.*?)\n---[ \t]*\n?(.*)$', text, re.DOTALL)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip()
    return meta, m.group(2)

def doc_h1_title(md):
    for line in md.splitlines():
        s = line.strip()
        if s.startswith('# '):
            return s[2:].strip()
    return None

def strip_tags_for_display(body):
    out = []
    for para in re.split(r'\n\s*\n', body.strip()):
        out.append(re.sub(r'^@(p|fig|code|table|note|gate)[ \t]+', '', para.strip()))
    return "\n\n".join(out)

sections = []
for sf in sorted(glob.glob('*.script.md')):
    nn = sf.split('-', 1)[0]
    meta, script_body = split_front_matter(read(sf))
    doc_md, doc_name = "", None
    for cand in sorted(glob.glob(nn + '-*.md')):
        if cand.endswith('.script.md'):
            continue
        doc_name = cand; doc_md = read(cand); break
    title = meta.get('title') or (doc_h1_title(doc_md) if doc_md else None) or os.path.splitext(sf)[0]
    cues = []
    cpath = 'audio/%s.cues.json' % nn
    if os.path.exists(cpath):
        try: cues = json.loads(read(cpath))
        except Exception: cues = []
    apath = 'audio/%s.mp3' % nn
    sections.append({
        'nn': nn, 'title': title,
        'stem': (os.path.splitext(doc_name)[0] if doc_name else nn),
        'doc': doc_md if doc_md else '_(학습 문서 %s-*.md 를 찾지 못했습니다.)_' % nn,
        'script': strip_tags_for_display(script_body),
        'audio': apath if os.path.exists(apath) else '',
        'cues': cues,
    })

if not sections:
    sys.exit('섹션을 구성하지 못했습니다.')

point_name = os.path.basename(folder.rstrip('/'))
marked_js = read(marked_path)

TEMPLATE = r'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ · 낭독 학습</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github.min.css">
<style>
@import url('https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.min.css');
:root{
  --paper:#fffdf9; --bg:#ece5d9; --ink:#221f1a; --soft:#544c40; --faint:#8b8173; --line:#e8dfcd;
  --accent:#b3541b; --accent-soft:#f3e7d6; --ring:rgba(179,84,27,.55);
  --info:#2b6cb0; --info-bg:#eef5fb; --warn:#b5560e; --warn-bg:#fdf1e3;
  --gate:#6b4fb0; --gate-bg:#f3effb; --note-bg:#f7f2e9; --bar:#2b2721;
}
*{box-sizing:border-box} html{scroll-behavior:smooth} html,body{margin:0}
body{font-family:'Pretendard',-apple-system,"Apple SD Gothic Neo",Segoe UI,Roboto,sans-serif;
  background:var(--bg); color:var(--ink); line-height:1.9; letter-spacing:-.003em; padding-bottom:84px}
#progress{position:fixed; top:0; left:0; height:3px; background:var(--accent); width:0; z-index:80; transition:width .1s}
#wrap{display:flex; min-height:100vh}
#side{width:264px; flex:0 0 264px; position:sticky; top:0; align-self:flex-start; height:100vh;
  overflow-y:auto; padding:26px 14px 100px; border-right:1px solid var(--line)}
#side h1{font-size:11px; letter-spacing:.12em; color:var(--faint); font-weight:700; margin:6px 10px 16px; text-transform:uppercase}
.navrow{display:flex; gap:9px; align-items:flex-start; width:100%; text-align:left; background:none; border:0;
  border-radius:9px; padding:9px 10px; cursor:pointer; color:var(--soft); font:inherit; line-height:1.4}
.navrow:hover{background:var(--accent-soft)}
.navrow.active{background:var(--accent-soft)}
.navrow.active .nt{color:var(--accent); font-weight:700}
.navrow .nn{color:var(--faint); font-variant-numeric:tabular-nums; font-weight:700; font-size:12px; padding-top:2px}
.navrow .nt{font-size:13.5px}
.subtoc{margin:2px 0 8px 30px; display:flex; flex-direction:column; border-left:1px solid var(--line)}
.sublink{display:block; color:var(--faint); text-decoration:none; font-size:12px; line-height:1.4; padding:5px 10px; border-left:2px solid transparent; margin-left:-1px}
.sublink:hover{color:var(--soft)}
.sublink.on{color:var(--accent); border-left-color:var(--accent); font-weight:600}
#content{flex:1 1 auto; min-width:0; display:flex; justify-content:center; padding:0 24px}
.col{width:100%; max-width:720px}
.sheet{width:100%; margin:34px 0 18px; background:var(--paper); border:1px solid var(--line);
  border-radius:16px; box-shadow:0 12px 44px rgba(60,40,20,.09); padding:50px 56px}
#doc{font-size:17px; overflow-wrap:break-word}
#doc>*{scroll-margin-top:20px; transition:opacity .35s ease}
#doc>h1:first-child{font-size:1.95em; line-height:1.28; font-weight:800; letter-spacing:-.02em; margin:.1em 0 1em; padding-bottom:.65em; border-bottom:2px solid var(--ink)}
#doc>h1:first-child::before{content:'학습 문서 · 튜터식 심층'; display:block; font-size:.38em; font-weight:700; letter-spacing:.14em; color:var(--accent); margin-bottom:1.1em}
#doc h2{font-size:1.38em; font-weight:800; letter-spacing:-.02em; margin:2.2em 0 .7em; line-height:1.35}
#doc h2::before{content:''; display:block; width:32px; height:3px; background:var(--accent); border-radius:2px; margin-bottom:.5em}
#doc h3{font-size:1.1em; font-weight:700; margin:1.5em 0 .5em}
#doc p,#doc li{font-size:1rem}
#doc p{margin:1.05em 0; text-wrap:pretty}
#doc strong{font-weight:700; color:#000}
#doc a{color:var(--accent)}
#doc em{font-style:normal; background:linear-gradient(transparent 60%,#f6dcbb 60%); padding:0 .04em}
#doc hr{border:0; border-top:1px solid var(--line); margin:2em 0}
#doc :not(pre)>code{background:#f1ece1; color:#7a3d12; padding:.1em .42em; border-radius:6px; font-size:.9em; font-family:'SF Mono',ui-monospace,Menlo,monospace}
#doc pre{background:#faf6ee; border:1px solid var(--line); border-radius:12px; padding:16px 18px; overflow-x:auto; line-height:1.62; font-size:13.5px; position:relative}
#doc pre code{font-family:'SF Mono',ui-monospace,Menlo,monospace}
#doc pre.code{padding-top:36px}
#doc pre.code::before{content:''; position:absolute; top:14px; left:18px; width:9px; height:9px; border-radius:50%; background:#e0a99a; box-shadow:15px 0 #e6cf9a,30px 0 #a6c9a0}
#doc pre.code::after{content:'code'; position:absolute; top:11px; right:16px; font-size:11px; color:var(--faint); letter-spacing:.08em}
#doc pre.diagram{background:#fcf9f3; border-style:dashed; padding-top:34px}
#doc pre.diagram::after{content:'그림'; position:absolute; top:11px; right:16px; font-size:11px; color:var(--faint); letter-spacing:.08em}
#doc pre.mermaid-card{background:var(--paper); border:1px solid var(--line); border-style:solid; padding:20px; text-align:center; white-space:normal; overflow-x:auto; line-height:normal}
#doc pre.mermaid-card::before, #doc pre.mermaid-card::after{content:none}
#doc pre.mermaid-card svg{max-width:100%; height:auto}
#doc .hljs{background:transparent; padding:0}
#doc img{display:block; max-width:100%; height:auto; margin:1.6em auto; border:1px solid var(--line); border-radius:12px; background:#fff; padding:12px}
#doc blockquote{--cq:var(--accent); margin:1.6em 0; padding:16px 22px; border-radius:10px; border:1px solid var(--line); border-left:4px solid var(--cq); background:var(--note-bg); color:#453e32; line-height:1.85}
#doc blockquote p{margin:.55em 0} #doc blockquote p:first-child{margin-top:0} #doc blockquote p:last-child{margin-bottom:0}
#doc blockquote p:first-child>strong:first-child{color:var(--cq)}
#doc blockquote.info{--cq:var(--info); background:var(--info-bg)}
#doc blockquote.warn{--cq:var(--warn); background:var(--warn-bg)}
#doc blockquote.gate{--cq:var(--gate); background:var(--gate-bg)}
#doc table{border-collapse:collapse; width:100%; margin:1.4em 0; font-size:.92em}
#doc th,#doc td{padding:9px 12px; text-align:left; border-bottom:1px solid var(--line)}
#doc th{background:#f2ebdf; font-weight:700} #doc tbody tr:nth-child(even){background:#fbf7ef}
#doc ol{padding-left:0; counter-reset:step; list-style:none}
#doc ol>li{position:relative; padding-left:2.3em; margin:.7em 0}
#doc ol>li::before{counter-increment:step; content:counter(step); position:absolute; left:0; top:.02em; width:1.55em; height:1.55em; background:var(--accent); color:#fff; border-radius:50%; font-size:.78em; font-weight:700; display:flex; align-items:center; justify-content:center}
#doc ul{padding-left:1.2em} #doc ul li{margin:.5em 0}
#doc .anc{display:inline-flex; align-items:center; justify-content:center; min-width:1.35em; height:1.35em; background:var(--accent); color:#fff; border-radius:50%; font-size:.76em; font-weight:700; padding:0 .18em; vertical-align:.06em}
#doc details{margin:1em 0 .3em; border:1px solid var(--line); border-radius:10px; background:var(--paper); padding:0 18px}
#doc summary{cursor:pointer; padding:12px 0; color:var(--cq,var(--gate)); font-weight:600; list-style:none; display:flex; align-items:center; gap:8px}
#doc summary::-webkit-details-marker{display:none}
#doc summary::before{content:'▸'; color:var(--cq,var(--gate)); font-size:.9em; transition:transform .18s ease}
#doc details[open] summary{border-bottom:1px solid var(--line)}
#doc details[open] summary::before{transform:rotate(90deg)}
#doc details>*:not(summary){padding-bottom:14px} #doc details[open] summary{margin-bottom:2px}
/* 낭독 하이라이트: 재생 중에만 '지금 문단'만 또렷하고 나머지는 물러난다(포커스+거터). 멈추면 전부 정상. */
/* 주변 흐림은 옵션(#dimtoggle) — .dimoff면 흐림만 끄고, 활성 문단 레일은 유지 */
#doc.playing:not(.dimoff)>*{opacity:.32}
#doc.playing:not(.dimoff)>.hl{opacity:1}
#doc.playing>.hl{position:relative}
#doc.playing>.hl::before{content:''; position:absolute; left:-18px; top:.2em; bottom:.2em; width:3px; border-radius:2px; background:var(--accent)}
#doc.playing>blockquote.hl::before{display:none}   /* 콜아웃은 이미 좌측 컬러 바가 있어 레일 생략 */
#scriptbox{width:100%; margin:0 0 30px}
#scriptbox details{border:1px dashed var(--line); border-radius:12px; background:var(--paper)}
#scriptbox summary{cursor:pointer; padding:12px 18px; color:var(--faint); font-size:13.5px}
#scripttext{padding:4px 22px 20px; white-space:pre-wrap; color:#5c564c; font-size:14.5px; line-height:1.85}
#bar{position:fixed; left:0; right:0; bottom:0; height:66px; background:var(--bar); color:#f3efe8; display:flex; align-items:center; gap:14px; padding:0 18px; z-index:70; box-shadow:0 -6px 20px rgba(0,0,0,.14)}
#bar button{background:none; border:0; color:#f3efe8; cursor:pointer; line-height:1}
#bar .icon{font-size:20px; width:34px; height:34px; border-radius:50%; display:inline-flex; align-items:center; justify-content:center}
#bar .icon:hover{background:rgba(255,255,255,.12)}
#playpause{font-size:24px; background:var(--accent); width:42px; height:42px}
#curlabel{font-size:13px; color:#cfc7ba; min-width:150px; max-width:230px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
#seekwrap{flex:1 1 auto; display:flex; align-items:center; gap:10px; min-width:120px}
#seek{flex:1 1 auto; accent-color:var(--accent); cursor:pointer}
#time{font-size:12px; color:#cfc7ba; font-variant-numeric:tabular-nums; min-width:86px; text-align:right}
#speed{background:#3a352e; color:#f3efe8; border:1px solid #55504785; border-radius:7px; padding:5px 7px; font:inherit; font-size:13px; cursor:pointer}
#dimtoggle{margin-left:2px; font-size:12px; padding:5px 10px; border:1px solid #55504785; border-radius:7px; background:#3a352e; color:#cfc7ba; cursor:pointer; white-space:nowrap}
#dimtoggle.on{background:var(--accent); color:#fff; border-color:transparent}
.hint{color:#a49c8f; font-size:11px}
#navtoggle{display:none; position:fixed; top:10px; left:12px; z-index:78; background:var(--paper); color:var(--ink); border:1px solid var(--line); border-radius:9px; width:38px; height:38px; font-size:18px; cursor:pointer; box-shadow:0 2px 8px rgba(0,0,0,.12)}
#ffind{position:fixed; top:22px; left:50%; z-index:90; pointer-events:none; background:rgba(20,18,15,.82); color:#fff; font-size:13px; font-weight:600; letter-spacing:.02em; padding:7px 14px; border-radius:20px; opacity:0; transform:translateX(-50%) translateY(-6px); transition:opacity .14s, transform .14s}
#ffind.show{opacity:1; transform:translateX(-50%) translateY(0)}
#gatehint{position:fixed; left:50%; bottom:82px; z-index:90; pointer-events:none; background:var(--gate); color:#fff; font-size:14px; font-weight:600; padding:9px 16px; border-radius:12px; box-shadow:0 4px 16px rgba(0,0,0,.22); opacity:0; transform:translateX(-50%) translateY(6px); transition:opacity .16s, transform .16s}
#gatehint.show{opacity:1; transform:translateX(-50%) translateY(0)}
@media (max-width:900px){
  #side{position:fixed; z-index:75; transform:translateX(-100%); transition:transform .2s; background:var(--paper); box-shadow:2px 0 16px rgba(0,0,0,.15)}
  #side.open{transform:none}
  #navtoggle{display:block}
  #content{padding:0 12px} .sheet{padding:32px 22px 40px}
  #curlabel,.hint{display:none}
}
@media (prefers-reduced-motion: reduce){ *,*::before,*::after{animation-duration:.01ms!important; transition-duration:.01ms!important} html{scroll-behavior:auto} }
</style>
</head>
<body>
<div id="progress"></div>
<button id="navtoggle" aria-label="목차 열기">☰</button>
<div id="wrap">
  <aside id="side"><h1>__POINT__</h1><div id="sections"></div></aside>
  <div id="content"><div class="col">
    <div class="sheet"><article id="doc"></article></div>
    <div id="scriptbox"><details>
      <summary>▸ 낭독 스크립트 보기 (귀로 듣는 내용)</summary>
      <div id="scripttext"></div>
    </details></div>
  </div></div>
</div>
<div id="bar">
  <button id="prev" class="icon" title="이전 섹션 (p)">⏮</button>
  <button id="playpause" class="icon" title="재생/일시정지 (space)">▶︎</button>
  <button id="next" class="icon" title="다음 섹션 (n)">⏭</button>
  <span id="curlabel"></span>
  <div id="seekwrap"><input id="seek" type="range" min="0" max="1000" value="0" step="1"><span id="time">0:00 / 0:00</span></div>
  <label style="font-size:12px;color:#cfc7ba">배속
    <select id="speed"><option>0.75</option><option selected>1</option><option>1.25</option><option>1.5</option><option>1.75</option><option>2</option></select>
  </label>
  <button id="dimtoggle" title="재생 중 주변 흐림 켜기/끄기">흐림 켬</button>
  <span class="hint">space 탭=재생/정지 · 길게=2배속 · ←/→ 5초 · ↑/↓ 배속 · n/p 섹션</span>
</div>
<div id="ffind">2배속</div>
<div id="gatehint">먼저 떠올려 보세요 · 스페이스로 계속</div>
<audio id="audio" preload="metadata"></audio>

<script>/*__MARKED__*/</script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/languages/groovy.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
const S = /*__DATA__*/;
const SPEEDS=[0.75,1,1.25,1.5,1.75,2];
const docEl=document.getElementById('doc'), scriptEl=document.getElementById('scripttext');
const navEl=document.getElementById('sections'), audio=document.getElementById('audio');
const curLabel=document.getElementById('curlabel'), seek=document.getElementById('seek');
const timeEl=document.getElementById('time'), speedSel=document.getElementById('speed'), ppBtn=document.getElementById('playpause');
const ffind=document.getElementById('ffind'), gatehint=document.getElementById('gatehint'), progEl=document.getElementById('progress');
let cur=-1, curCues=[], curMap=[], curHl=-1, pausedGates=new Set();
let rows=[], subLinks=[], subHeads=[];

if(window.marked&&marked.setOptions) marked.setOptions({gfm:true, breaks:false});
if(window.mermaid) try{ mermaid.initialize({startOnLoad:false, theme:'base', themeVariables:{fontFamily:"'Pretendard',sans-serif", fontSize:'14px', primaryColor:'#fff8f0', primaryBorderColor:'#b3541b', primaryTextColor:'#221f1a', lineColor:'#8a8377', secondaryColor:'#eef7ee', tertiaryColor:'#fdf3f0', background:'#fffdf9'}}); }catch(e){}
function md(t){ try{ return window.marked?marked.parse(t):t; }catch(e){ return '<pre>'+esc(t)+'</pre>'; } }
function esc(x){return x.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function fmt(t){t=Math.floor(t||0);return Math.floor(t/60)+':'+String(t%60).padStart(2,'0');}

// 렌더된 문서에 시각 강화: 신택스 하이라이트 · 콜아웃 카드 · 코드/그림 구분 · 앵커 배지
function enhanceDoc(){
  // Mermaid 다이어그램 렌더(있으면). <pre> 태그는 유지하고 안에 SVG만 그려 넣어 하이라이트 정렬을 깨지 않는다.
  if(window.mermaid){ docEl.querySelectorAll('pre>code.language-mermaid').forEach(function(code){
    var pre=code.parentElement, src=code.textContent;
    try{ mermaid.render('mmd'+Math.random().toString(36).slice(2,9), src).then(function(r){ pre.innerHTML=r.svg; pre.classList.add('mermaid-card'); }).catch(function(){}); }catch(e){}
  }); }
  if(window.hljs){ docEl.querySelectorAll('pre code[class*="language-"]:not(.language-mermaid)').forEach(function(el){ try{hljs.highlightElement(el);}catch(e){} }); }
  docEl.querySelectorAll('blockquote').forEach(function(bq){
    var t=(bq.textContent||'').slice(0,46), c='';
    if(bq.querySelector('details')) c='gate';                 // 게이트 = 답을 접은 인출 블록(이모지에 의존하지 않음)
    else if(/오해/.test(t)) c='warn';
    else if(/심화|읽어보기|참고|배경|잠깐/.test(t)) c='info';
    if(c) bq.classList.add(c);
    var lead=bq.querySelector('strong')||bq.querySelector('p');  // 라벨 선두의 이모지 제거(문서가 조잡해 보이지 않게)
    if(lead) lead.innerHTML=lead.innerHTML.replace(/^\s*(?:🧠|💡|👏|🎉|🔥|📌|🚀|💥|✨|⭐|⚠|ℹ|✅|❗|❓|➡|✔)️?\s*/,'');
  });
  docEl.querySelectorAll('pre').forEach(function(pre){
    var code=pre.querySelector('code');
    if(code && /language-mermaid/.test(code.className||'')) return;   // mermaid는 위에서 다이어그램으로 렌더
    var lang=!!(code&&/language-/.test(code.className||''));
    var s=pre.textContent||'', diag=/[│├─└┌┐┘▼▶►◄╭╮╯╰↑↓→←↔⟶⟵]|──|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫]/.test(s);
    pre.classList.add(lang?'code':(diag?'diagram':'code'));   // 언어 없는 펜스(도식·절차 목록)는 '그림' 카드로
  });
  docEl.querySelectorAll('p,li').forEach(function(el){
    if(/[❶-❿]/.test(el.textContent)) el.innerHTML=el.innerHTML.replace(/([❶-❿])/g,'<span class="anc">$1</span>');
  });
  docEl.querySelectorAll('p,li,h1,h2,h3,h4').forEach(function(el){   // 장식용 이모지 제거(조잡함 방지)
    if(/[👏🎉🔥✨⭐🚀💥📌🎯🙌💪👍]/.test(el.textContent)) el.innerHTML=el.innerHTML.replace(/\s*(?:👏|🎉|🔥|✨|⭐|🚀|💥|📌|🎯|🙌|💪|👍)️?/g,'');
  });
}

function classify(el){
  const t=el.tagName;
  if(t==='PRE') return 'code';
  if(t==='TABLE') return 'table';
  if(t==='BLOCKQUOTE') return 'note';
  if(t==='UL'||t==='OL') return 'p';
  if(t==='P') return el.querySelector('img')?'fig':'p';
  return 'skip';   // 제목(H*) 등은 하이라이트 대상 아님(문맥으로 스크롤만 됨)
}
function buildCueMap(cues){
  const slots=[...docEl.children].map(el=>({el,kind:classify(el)}));
  let ptr=0; const map=[];
  for(const c of cues){
    const want = c.type==='gate' ? 'note' : c.type;   // 게이트는 문서에서 인용구(blockquote)로 그려진다
    let found=null;
    for(let j=ptr;j<slots.length;j++){ if(slots[j].kind===want){ found=slots[j].el; ptr=j+1; break; } }
    map.push(found);
  }
  return map;
}
function setHl(idx){
  if(idx===curHl) return;
  if(curHl>=0&&curMap[curHl]) curMap[curHl].classList.remove('hl');
  curHl=idx;
  const el=curMap[idx];
  if(el){ el.classList.add('hl'); el.scrollIntoView({behavior:'smooth', block:'center'}); }
}
function syncHl(){
  if(!curCues.length) return;
  let idx=-1;
  for(let j=0;j<curCues.length;j++){ if(curCues[j].start<=audio.currentTime+0.02) idx=j; else break; }
  if(idx<0) return;
  // 게이트 자동 멈춤: 방금 게이트(질문) 청크가 끝나 다음 청크(답)로 넘어가려는 순간, 한 번만 멈춘다
  if(idx>=1 && curCues[idx-1] && curCues[idx-1].type==='gate' && !pausedGates.has(idx-1)){
    pausedGates.add(idx-1);
    if(!audio.paused) audio.pause();
    setHl(idx-1);                 // 떠올리는 동안 시선은 질문(게이트)에 머문다
    gatehint.classList.add('show');
    return;
  }
  setHl(idx);
}

function buildNav(){
  S.forEach(function(s,i){
    var b=document.createElement('button'); b.className='navrow';
    b.innerHTML='<span class="nn">'+esc(s.nn)+'</span><span class="nt">'+esc(s.title)+'</span>';
    b.onclick=function(){ this.blur(); select(i,true); };
    navEl.appendChild(b); rows.push(b);
  });
}
// 활성 섹션 아래에 그 문서의 H2 목차를 펼친다(스크롤 추적)
function renderSubTOC(i){
  var old=navEl.querySelector('.subtoc'); if(old) old.remove();
  subHeads=[].slice.call(docEl.querySelectorAll('h2')); subLinks=[];
  if(!subHeads.length) return;
  var box=document.createElement('div'); box.className='subtoc';
  subHeads.forEach(function(h,j){
    h.id='h'+j;
    var a=document.createElement('a'); a.className='sublink'; a.textContent=h.textContent; a.href='#h'+j;
    a.onclick=function(e){ e.preventDefault(); h.scrollIntoView({behavior:'smooth', block:'start'}); var sd=document.getElementById('side'); if(sd) sd.classList.remove('open'); };
    box.appendChild(a); subLinks.push(a);
  });
  if(rows[i]) rows[i].insertAdjacentElement('afterend', box);
}
function spy(){
  var de=document.documentElement, denom=(de.scrollHeight-de.clientHeight)||1;
  progEl.style.width=(de.scrollTop/denom*100)+'%';
  if(subHeads.length){ var c=0; subHeads.forEach(function(h,j){ if(h.getBoundingClientRect().top<150) c=j; });
    subLinks.forEach(function(l,j){ l.classList.toggle('on',j===c); }); }
}
window.addEventListener('scroll', spy, {passive:true});

function select(i, play){
  if(i<0||i>=S.length) return;
  cur=i; var s=S[i];
  docEl.innerHTML=md(s.doc);
  enhanceDoc();
  scriptEl.textContent=s.script||'(스크립트 없음)';
  curCues=s.cues||[]; curMap=buildCueMap(curCues); curHl=-1; pausedGates=new Set(); gatehint.classList.remove('show');
  audio.src=s.audio||''; audio.playbackRate=parseFloat(speedSel.value);
  curLabel.textContent=s.nn+' · '+s.title;
  rows.forEach(function(r,j){ r.classList.toggle('active',j===i); });
  renderSubTOC(i);
  window.scrollTo(0,0);
  var side=document.getElementById('side'); if(side) side.classList.remove('open');
  spy(); syncHl();
  if(play&&s.audio){ audio.play().catch(function(){}); }
}
function stepSpeed(d){ var idx=SPEEDS.indexOf(parseFloat(speedSel.value)); if(idx<0)idx=1;
  idx=Math.max(0,Math.min(SPEEDS.length-1,idx+d)); speedSel.value=String(SPEEDS[idx]); audio.playbackRate=SPEEDS[idx]; }

ppBtn.onclick=function(){ this.blur(); if(audio.paused)audio.play(); else audio.pause(); };
document.getElementById('prev').onclick=function(){ this.blur(); select(cur-1,true); };
document.getElementById('next').onclick=function(){ this.blur(); select(cur+1,true); };
audio.onplay=function(){ ppBtn.textContent='⏸'; gatehint.classList.remove('show'); docEl.classList.add('playing'); };
audio.onpause=function(){ ppBtn.textContent='▶︎'; docEl.classList.remove('playing'); };   // 멈추면 전부 정상으로
audio.onended=function(){ if(cur<S.length-1) select(cur+1,true); else docEl.classList.remove('playing'); };
audio.ontimeupdate=function(){ if(audio.duration){ seek.value=String((audio.currentTime/audio.duration*1000)||0);
  timeEl.textContent=fmt(audio.currentTime)+' / '+fmt(audio.duration); } syncHl(); };
audio.onloadedmetadata=function(){ timeEl.textContent='0:00 / '+fmt(audio.duration); };
seek.oninput=function(){ if(audio.duration) audio.currentTime=seek.value/1000*audio.duration; };
speedSel.onchange=function(){ audio.playbackRate=parseFloat(speedSel.value); };
// 스페이스: 짧게 탭=재생/정지, 길게 누르면=2배속(떼면 선택된 배속으로 복귀)
let spaceHeld=false, holdEngaged=false, holdTimer=null;
function editing(t){ return t==='INPUT'||t==='SELECT'||t==='TEXTAREA'; }
document.addEventListener('keydown',function(e){
  if(editing(e.target.tagName)) return;
  if(e.code==='Space'){
    e.preventDefault();
    if(e.repeat) return;
    spaceHeld=true;
    holdTimer=setTimeout(function(){ if(spaceHeld){ holdEngaged=true; if(audio.paused) audio.play().catch(function(){}); audio.playbackRate=2; ffind.classList.add('show'); } }, 180);
    return;
  }
  if(e.key==='ArrowRight'){ e.preventDefault(); audio.currentTime=Math.min(audio.duration||0,audio.currentTime+5); }
  else if(e.key==='ArrowLeft'){ e.preventDefault(); audio.currentTime=Math.max(0,audio.currentTime-5); }
  else if(e.key==='ArrowUp'){ e.preventDefault(); stepSpeed(1); }
  else if(e.key==='ArrowDown'){ e.preventDefault(); stepSpeed(-1); }
  else if(e.key==='n'||e.key==='j'){ select(cur+1,true); }
  else if(e.key==='p'||e.key==='k'){ select(cur-1,true); }
});
document.addEventListener('keyup',function(e){
  if(e.code!=='Space') return;
  if(editing(e.target.tagName)) return;
  e.preventDefault();
  spaceHeld=false; clearTimeout(holdTimer);
  if(holdEngaged){ holdEngaged=false; audio.playbackRate=parseFloat(speedSel.value); ffind.classList.remove('show'); }
  else { audio.paused?audio.play():audio.pause(); }   // 짧은 탭
});
var _nt=document.getElementById('navtoggle'); if(_nt) _nt.onclick=function(){ this.blur(); var sd=document.getElementById('side'); if(sd) sd.classList.toggle('open'); };
// 재생 중 주변 흐림 토글 (기본 켜짐, 선택은 브라우저에 기억)
var dimBtn=document.getElementById('dimtoggle');
var dimOn=true; try{ dimOn = localStorage.getItem('learn.focusdim')!=='off'; }catch(e){}
function applyDim(){ docEl.classList.toggle('dimoff', !dimOn); if(dimBtn){ dimBtn.classList.toggle('on', dimOn); dimBtn.textContent = dimOn?'흐림 켬':'흐림 끔'; } }
if(dimBtn) dimBtn.onclick=function(){ this.blur(); dimOn=!dimOn; try{ localStorage.setItem('learn.focusdim', dimOn?'on':'off'); }catch(e){} applyDim(); };
applyDim();
buildNav(); select(0,false);
</script>
</body>
</html>
'''

def render_player(secs):
    dj = json.dumps(secs, ensure_ascii=False).replace('</', '<\\/')
    return (TEMPLATE
            .replace('__TITLE__', html.escape(secs[0]['title']))
            .replace('__POINT__', html.escape(point_name))
            .replace('/*__MARKED__*/', marked_js)
            .replace('/*__DATA__*/', dj))

# 기본: 섹션당 하나의 player(<NN-슬러그>.player.html). LEARN_PLAYER=point면 전 섹션 통합 player.html.
mode = os.environ.get('LEARN_PLAYER', 'section')
if mode == 'point':
    with open('player.html', 'w', encoding='utf-8') as f:
        f.write(render_player(sections))
    print('생성: %s/player.html  (통합, 섹션 %d개)' % (folder, len(sections)))
else:
    names = []
    for s in sections:
        fn = s['stem'] + '.player.html'
        with open(fn, 'w', encoding='utf-8') as f:
            f.write(render_player([s]))
        names.append(fn)
    print('생성: %s/ — 섹션별 player %d개: %s' % (folder, len(sections), ', '.join(names)))
PY

# 하이라이트 1:1 정렬 검증 (node 있을 때만, 경고만 — 렌더 실패시키지 않음)
if command -v node >/dev/null 2>&1; then
  node "$SKILL_DIR/scripts/verify-align.js" "$FOLDER" || true
else
  echo "(node 없음 — 하이라이트 정렬 검증 건너뜀)"
fi
