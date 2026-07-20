#!/usr/bin/env python3
"""Gateway MCP locale: quality gate federato davanti a Understory."""
import fcntl, json, os, re, socket, uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

HOST=os.getenv("LIBRARIAN_BIND_HOST","127.0.0.1"); PORT=int(os.getenv("LIBRARIAN_PORT","3810"))
UPSTREAM=os.getenv("LIBRARIAN_UNDERSTORY_URL","http://127.0.0.1:3800").rstrip("/")
MOUNT=Path(os.getenv("SHARED_MOUNT_PATH","/mnt/ai-rig-shared")); BUNDLE=MOUNT/"understory"/"bundle"
PRIVATE=MOUNT/"librarian"/"agents"
PUBLISHED=MOUNT/"librarian"/"published_ids.jsonl"
SHARED={"verified_success","verified_failure","human_confirmed"}
ALL=SHARED|{"raw","pending_review","candidate_success","inconclusive","superseded","revoked"}
AGENTS={"devin","teacher","hermes"}

def slug(value,fallback="general"):
    return re.sub(r"[^a-z0-9_-]+","-",str(value or "").lower()).strip("-") or fallback
def now(): return datetime.now(timezone.utc).isoformat()
def role():
    value=slug(os.getenv("AI_RIG_ROLE",""),"")
    if value in AGENTS:return value
    host=socket.gethostname().lower(); return next((x for x in AGENTS if x in host),"unknown")
def embedded(content):
    out={}
    for key in ("memory_id","source_agent","domain","status","polarity","created_at","evidence","confidence","provenance"):
        match=re.search(rf"(?mi)^\s*-?\s*{key}\s*:\s*(.+?)\s*$",content or "")
        if match:out[key]=match.group(1).strip()
    return out
def metadata(args):
    inside=embedded(args.get("content","")); get=lambda key,default=None:args.get(key,inside.get(key,default))
    status=slug(get("status","pending_review")); status=status if status in ALL else "pending_review"
    source=slug(get("source_agent",role()),"unknown"); source=source if source in AGENTS else "unknown"
    try: confidence=max(0.0,min(1.0,float(get("confidence",.5))))
    except (TypeError,ValueError): confidence=.5
    return {"memory_id":get("memory_id",f"mem-{uuid.uuid4().hex}"),"source_agent":source,
      "domain":slug(get("domain","general")),"status":status,
      "polarity":"negative" if slug(get("polarity","negative" if status=="verified_failure" else "positive"))=="negative" else "positive",
      "created_at":get("created_at",now()),"evidence":str(get("evidence","")).strip(),
      "confidence":confidence,"provenance":str(get("provenance","librarian_mcp")).strip(),
      "project":slug(get("project","general"))}
def publishable(meta):
    return meta["status"] in SHARED and meta["source_agent"] in AGENTS and bool(meta["evidence"]) and bool(meta["provenance"]) and meta["confidence"]>=.5
def quarantine(kind,meta,payload):
    agent=meta["source_agent"] if meta["source_agent"] in AGENTS else "unknown"; directory=PRIVATE/agent
    directory.mkdir(parents=True,exist_ok=True); path=directory/"quarantine.jsonl"
    with path.open("a",encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(),fcntl.LOCK_EX)
        stream.write(json.dumps({"recorded_at":now(),"kind":kind,"metadata":meta,"payload":payload},ensure_ascii=False)+"\n")
        stream.flush(); os.fsync(stream.fileno()); fcntl.flock(stream.fileno(),fcntl.LOCK_UN)
    return path
def already_published(memory_id):
    if not PUBLISHED.exists():return False
    return any(line.strip()==memory_id for line in PUBLISHED.read_text(encoding="utf-8",errors="ignore").splitlines())
def mark_published(memory_id):
    PUBLISHED.parent.mkdir(parents=True,exist_ok=True)
    with PUBLISHED.open("a",encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(),fcntl.LOCK_EX)
        known={line.strip() for line in PUBLISHED.read_text(encoding="utf-8",errors="ignore").splitlines()} if PUBLISHED.exists() else set()
        if memory_id not in known:stream.write(memory_id+"\n"); stream.flush(); os.fsync(stream.fileno())
        fcntl.flock(stream.fileno(),fcntl.LOCK_UN)

def decode(response):
    body=response.read().decode("utf-8",errors="replace")
    if "application/json" in response.headers.get("content-type",""): return json.loads(body) if body else {}
    result={}
    for line in body.splitlines():
        if line.startswith("data:"):
            try:result=json.loads(line[5:].strip())
            except json.JSONDecodeError:pass
    return result
def rpc(payload,session=None):
    headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
    if session:headers["Mcp-Session-Id"]=session
    with urlopen(Request(UPSTREAM+"/mcp",data=json.dumps(payload).encode(),headers=headers),timeout=90) as response:
        return decode(response),response.headers.get("Mcp-Session-Id")
def upstream(name,args):
    init,session=rpc({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ai-rig-librarian","version":"1.0"}}})
    if init.get("error"):raise RuntimeError(str(init["error"]))
    rpc({"jsonrpc":"2.0","method":"notifications/initialized"},session)
    result,_=rpc({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":name,"arguments":args}},session)
    if result.get("error"):raise RuntimeError(str(result["error"]))
    return result.get("result",{})

def description(path):
    text=path.read_text(encoding="utf-8",errors="replace")[:5000]
    for key in ("description","title"):
        match=re.search(rf"(?mi)^{key}:\s*(.+)$",text)
        if match:return match.group(1).strip().strip("\"'")
    match=re.search(r"(?m)^#\s+(.+)$",text); return match.group(1).strip() if match else path.stem.replace("-"," ")
def seed(limit=3000):
    root=BUNDLE/"shared"; segments=[]
    if root.is_dir():
        for domain in sorted(p for p in root.iterdir() if p.is_dir()):
            files=[p for p in domain.rglob("*.md") if p.name not in {"index.md","log.md"}]
            if files:segments.append(f"* {domain.name}/ — {len(files)} concepts: "+"; ".join(description(p) for p in files[:10]))
    return ("Verified shared memory by domain:\n"+("\n".join(segments) or "(empty)"))[:limit]
def instructions():
    return ("The Librarian is persistent federated memory for DEVIN, TEACHER and HERMES.\n\n"+seed()+
      "\n\nCompact reasoning protocol: recall relevant verified memory; separate facts, hypotheses and unknowns; "
      "make the smallest useful risk-aware plan; act with tools; verify with observable evidence; after two "
      "equivalent failures change strategy; publish only verified learning. Before a related answer use "
      "memory_query. Unverified additions are privately quarantined. verified_failure is only an anti-pattern.")
def text(value):return {"content":[{"type":"text","text":value}]}

def query(args):
    guard="\n\nPOLICY: Answer only from /shared. Exclude raw, quarantine, pending, inconclusive, superseded and revoked. Preserve source_agent, status, polarity, evidence and citations. verified_failure is an anti-pattern, never advice."
    return upstream("memory_query",{"question":str(args.get("question","")).strip()+guard})
def add(args):
    meta=metadata(args); content=str(args.get("content","")).strip()
    if not content:raise ValueError("content is required")
    if already_published(meta["memory_id"]):return text(f"Already published: {meta['memory_id']}")
    if not publishable(meta):
        path=quarantine("add",meta,{"content":content,"suggested_path":args.get("suggested_path")})
        return text(f"Quarantined as {meta['status']}; not published. Audit: {path}")
    header="Federated memory metadata:\n"+"\n".join(f"- {k}: {v}" for k,v in meta.items())
    path=f"/shared/{meta['domain']}/{meta['source_agent']}-{meta['project']}.md"
    result=upstream("memory_add",{"content":header+"\n\n"+content,"suggested_path":path})
    mark_published(meta["memory_id"])
    return result
def update(args):
    instruction=str(args.get("instruction","")).strip(); approval=slug(args.get("approval_status","pending_review"))
    meta=metadata({**args,"status":approval,"content":instruction})
    if approval not in {"verified_success","human_confirmed"} or not meta["evidence"]:
        return text(f"Update proposal quarantined. Audit: {quarantine('update_proposal',meta,{'instruction':instruction})}")
    return upstream("memory_update",{"instruction":"Apply only under /shared; preserve history and remove contradictory active claims.\n\n"+instruction})
def qcount():
    return sum(sum(1 for line in p.read_text(encoding="utf-8",errors="ignore").splitlines() if line.strip()) for p in PRIVATE.glob("*/quarantine.jsonl")) if PRIVATE.exists() else 0
def status(_):return text(json.dumps({"role":role(),"quarantine_records":qcount(),"understory":upstream("memory_status",{})},ensure_ascii=False,indent=2))
def maintain(args):
    if args.get("repair") is True and slug(args.get("approval_status"))=="human_confirmed":return upstream("memory_maintain",{})
    return text("Read-only report; repair requires human_confirmed:\n"+json.dumps(upstream("memory_status",{})))

TOOLS=[
 {"name":"memory_query","description":"Query verified memory across all agents.\n\n"+seed(),"inputSchema":{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}},
 {"name":"memory_add","description":"Submit knowledge; unverified content is quarantined.","inputSchema":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string"},"source_agent":{"type":"string"},"domain":{"type":"string"},"evidence":{"type":"string"},"confidence":{"type":"number"},"polarity":{"type":"string"},"project":{"type":"string"}},"required":["content"]}},
 {"name":"memory_update","description":"Propose or apply a verified update.","inputSchema":{"type":"object","properties":{"instruction":{"type":"string"},"approval_status":{"type":"string"},"evidence":{"type":"string"}},"required":["instruction"]}},
 {"name":"memory_status","description":"Deterministic status and graph health.","inputSchema":{"type":"object","properties":{}}},
 {"name":"memory_maintain","description":"Read-only lint; repair requires human approval.","inputSchema":{"type":"object","properties":{"repair":{"type":"boolean"},"approval_status":{"type":"string"}}}}]
HANDLERS={"memory_query":query,"memory_add":add,"memory_update":update,"memory_status":status,"memory_maintain":maintain}

class Handler(BaseHTTPRequestHandler):
    server_version="AIRigLibrarian/1.0"
    def reply(self,code,payload):
        body=json.dumps(payload,ensure_ascii=False).encode(); self.send_response(code); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path=="/health":self.reply(200,{"ok":True,"service":"librarian","role":role(),"understory":UPSTREAM,"quarantine":qcount()})
        elif self.path=="/seed":self.reply(200,{"seed":seed()})
        else:self.reply(404,{"error":"not found"})
    def do_POST(self):
        if self.path!="/mcp":return self.reply(404,{"error":"not found"})
        request_id=None
        try:
            request=json.loads(self.rfile.read(int(self.headers.get("Content-Length","0"))) or b"{}"); method=request.get("method"); request_id=request.get("id")
            if method=="initialize":result={"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"ai-rig-librarian","version":"1.0"},"instructions":instructions()}
            elif method=="notifications/initialized":return self.reply(200,{})
            elif method=="tools/list":result={"tools":TOOLS}
            elif method=="tools/call":
                params=request.get("params",{}); name=params.get("name","")
                if name not in HANDLERS:raise ValueError(f"unknown tool: {name}")
                result=HANDLERS[name](params.get("arguments",{}))
            else:return self.reply(200,{"jsonrpc":"2.0","id":request_id,"error":{"code":-32601,"message":"Method not found"}})
            self.reply(200,{"jsonrpc":"2.0","id":request_id,"result":result})
        except (ValueError,RuntimeError,HTTPError,URLError,OSError) as exc:self.reply(200,{"jsonrpc":"2.0","id":request_id,"error":{"code":-32000,"message":str(exc)}})
    def log_message(self,fmt,*args):print(f"[librarian] {fmt%args}",flush=True)

if __name__=="__main__":
    PRIVATE.mkdir(parents=True,exist_ok=True); print(f"Librarian http://{HOST}:{PORT}; upstream={UPSTREAM}",flush=True); ThreadingHTTPServer((HOST,PORT),Handler).serve_forever()
