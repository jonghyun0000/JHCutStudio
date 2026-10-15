"use strict";
const AccuracyReview = (() => {
  const uuid = () => globalThis.crypto.randomUUID();
  const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const allowedKinds = new Set(["speech","nonspeech","excluded"]);
  const allowedConditions = new Set(["quiet","backgroundMusic","noise","shortResponse","overlap","unknown"]);
  const bytes=s=>new TextEncoder().encode(s).length;
  const clone=s=>({...s,conditions:[...s.conditions]});
  const binding=t=>({sourceFile:t.sourceFile,sourceSHA256:t.sourceSHA256,segmentID:t.segmentID,sourceStart:t.sourceStart,sourceEnd:t.sourceEnd});
  const sameBinding=(a,b)=>Object.keys(binding(a)).every(k=>a[k]===b[k]);
  function parseJSON(raw) {
    if(typeof raw!=="string" || bytes(raw)>4000000) throw Error("JSON 파일 크기를 확인하세요.");
    let i=0,nodes=0;const space=()=>{while(i<raw.length && /[\x20\t\r\n]/.test(raw[i]))i++;};
    const take=c=>{space();if(raw[i++]!==c)throw Error("JSON 구조를 확인하세요.");};
    const string=()=>{take('"');const start=i-1;while(i<raw.length){const c=raw[i++];if(c==='\\')i++;else if(c==='"')return JSON.parse(raw.slice(start,i));}throw Error("JSON 문자열을 확인하세요.");};
    function value(depth){space();if(depth>64 || ++nodes>400000 || i>=raw.length)throw Error("JSON 깊이·항목 수를 확인하세요.");
      if(raw[i]==='{'){i++;space();const keys=new Set();if(raw[i]==='}'){i++;return;}while(true){const key=string();if(keys.has(key))throw Error("JSON에 중복된 필드가 있습니다.");keys.add(key);take(':');value(depth+1);space();if(raw[i]==='}'){i++;return;}take(',');}}
      else if(raw[i]==='['){i++;space();if(raw[i]===']'){i++;return;}while(true){value(depth+1);space();if(raw[i]===']'){i++;return;}take(',');}}
      else if(raw[i]==='"')string();else{const start=i;while(i<raw.length && !/[\x20\t\r\n,\]}]/.test(raw[i]))i++;if(i===start)throw Error("JSON 값을 확인하세요.");}
    }
    value(0);space();if(i!==raw.length)throw Error("JSON 뒤쪽 형식을 확인하세요.");return JSON.parse(raw);
  }
  function validateTemplate(t) {
    if (!t || t.schemaVersion!==1 || t.overlapPolicy!=="exclude" || !uuidPattern.test(t.revisionID) ||
        t.parentRevisionID!=null && (!uuidPattern.test(t.parentRevisionID) || t.parentRevisionID.toLowerCase()===t.revisionID.toLowerCase()) ||
        typeof t.sourceFile!=="string" || !t.sourceFile || bytes(t.sourceFile)>1024 ||
        typeof t.segmentID!=="string" || !t.segmentID || bytes(t.segmentID)>256 ||
        !/^[0-9a-f]{64}$/.test(t.sourceSHA256) || !Number.isFinite(t.sourceStart) || !Number.isFinite(t.sourceEnd) ||
        t.sourceStart<0 || t.sourceEnd<=t.sourceStart || !["und","ko","ja","en"].includes(t.language)) throw Error("검수 원본·범위·버전·언어가 올바르지 않습니다.");
  }
  // Partial drafts may have gaps; malformed/overlapping rows cannot poison restore or editing.
  function validateDraftSpans(template,spans) {
    validateTemplate(template);
    if (!Array.isArray(spans) || spans.length>20000) throw Error("구간 수를 확인하세요.");
    let cursor=template.sourceStart,total=0;const ids=new Set();
    const sorted=spans.map(s=>{
      if (!s || typeof s.text!=="string" || typeof s.reason!=="string" || !Array.isArray(s.conditions)) throw Error("구간 문구·조건의 형식을 확인하세요.");
      return clone(s);
    }).sort((a,b)=>a.start-b.start);
    for (const s of sorted) {
      if (!Number.isFinite(s.start) || !Number.isFinite(s.end) || s.start<cursor-1e-6 || s.start<template.sourceStart || s.end<=s.start || s.end>template.sourceEnd+1e-6 || !allowedKinds.has(s.kind)) throw Error("구간의 겹침·원본 범위·시각을 확인하세요.");
      if (!uuidPattern.test(s.id) || ids.has(s.id.toLowerCase())) throw Error("중복된 구간입니다.");ids.add(s.id.toLowerCase());
      if (!s.conditions.length || s.conditions.some(c=>!allowedConditions.has(c)) || new Set(s.conditions).size!==s.conditions.length) throw Error("촬영 조건을 확인하세요.");
      const amount=bytes(s.text+s.reason);total+=amount;
      if (amount>65536 || total>2000000) throw Error("대본이 너무 큽니다.");
      cursor=s.end;
    }
    return sorted;
  }
  function validateSpans(template, spans) {
    const sorted=validateDraftSpans(template,spans);
    if (!sorted.length) throw Error("구간을 추가하세요.");
    let cursor=template.sourceStart;
    for (const s of sorted) {
      if (Math.abs(s.start-cursor)>1e-6) throw Error("선택 구간 전체를 빈틈과 겹침 없이 나눠주세요.");
      const text=s.text.trim(),reason=s.reason.trim();
      if (s.kind==="speech") {
        if (!["ko","ja","en"].includes(template.language) || !/[\p{L}\p{N}]/u.test(text) || s.conditions.includes("overlap")) throw Error("대사와 언어를 확인하세요. 겹친 발화는 제외로 표시하세요.");
      } else if (text || s.kind==="excluded" && !reason) throw Error("비발화에는 대사를 넣지 않고, 제외에는 사유를 적어주세요.");
      cursor=s.end;
    }
    if (Math.abs(cursor-template.sourceEnd)>1e-6) throw Error("선택 구간 끝까지 검수 구간을 나눠주세요.");
    return sorted;
  }
  function validateReference(ref) {
    const spans=validateSpans(ref,ref.spans);
    for (const k of ["textReviewed","activityReviewed","timingReviewed","draftExposure"]) if (typeof ref[k]!=="boolean") throw Error("검수 확인의 형식을 확인하세요.");
    if (!["pending","human-listened"].includes(ref.reviewMethod) || typeof ref.reviewer!=="string" && ref.reviewer!=null || ref.reviewer!=null && bytes(ref.reviewer)>256 ||
        ref.reviewedAt!=null && (typeof ref.reviewedAt!=="string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(ref.reviewedAt) || !Number.isFinite(Date.parse(ref.reviewedAt)))) throw Error("검수자·검수 시각을 확인하세요.");
    const reviewed=ref.textReviewed && ref.activityReviewed && ref.reviewMethod==="human-listened" && !!ref.reviewer?.trim() && ref.reviewedAt!=null;
    if ((ref.textReviewed || ref.activityReviewed || ref.timingReviewed) && !reviewed || ref.timingReviewed && (!ref.textReviewed || !ref.activityReviewed)) throw Error("검수 확인과 청취 기록이 맞지 않습니다.");
    if (reviewed && spans.some(s=>s.kind==="excluded" && ["사람 검수 미완료","미검수 공백"].includes(s.reason.trim()))) throw Error("미검수 구간을 확인하세요.");
    return spans;
  }
  function exportReference(template, spans, review) {
    validateTemplate(template);
    const draft={...template,language:review.language};
    const checked=validateSpans(draft,spans);
    if (typeof review.reviewer!=="string" || !review.reviewer.trim() || bytes(review.reviewer.trim())>256 || review.textReviewed!==true || review.activityReviewed!==true || typeof review.timingReviewed!=="boolean" || typeof review.draftExposure!=="boolean") throw Error("이름과 실제 청취·대사·발화 구간 검수 확인이 필요합니다.");
    if (checked.some(s=>s.kind==="excluded" && ["사람 검수 미완료","미검수 공백"].includes(s.reason.trim()))) throw Error("미검수 표시를 실제 제외 사유로 바꾸거나 해당 구간을 검수하세요.");
    return {...draft,revisionID:uuid(),parentRevisionID:template.revisionID,
      reviewer:review.reviewer.trim(),reviewedAt:new Date().toISOString().replace(/\.\d{3}Z$/,"Z"),reviewMethod:"human-listened",
      textReviewed:true,activityReviewed:true,timingReviewed:review.timingReviewed,draftExposure:review.draftExposure,spans:checked};
  }
  function fillGaps(template,spans) {
    const sorted=validateDraftSpans(template,spans);let cursor=template.sourceStart;const result=[];
    for (const s of sorted) {
      if (s.start>cursor+1e-6) result.push({id:uuid(),start:cursor,end:s.start,kind:"excluded",text:"",reason:"미검수 공백",conditions:["unknown"]});
      result.push(s);cursor=s.end;
    }
    if (cursor<template.sourceEnd-1e-6) result.push({id:uuid(),start:cursor,end:template.sourceEnd,kind:"excluded",text:"",reason:"미검수 공백",conditions:["unknown"]});
    return result;
  }
  class Session {
    constructor(template) {
      validateTemplate(template);this.template=JSON.parse(JSON.stringify(template));
      this.spans=validateDraftSpans(template,template.spans);this.baseRevisionID=template.revisionID;
      this.language=template.language;this.reviewer=template.reviewer||"";this.draftExposure=!!template.draftExposure;this.editID=null;
    }
    beginEdit(id) {const row=this.spans.find(s=>s.id===id);if(!row)throw Error("편집할 구간을 찾지 못했습니다.");this.editID=id;return clone(row);}
    cancelEdit() {this.editID=null;}
    commit(row) {
      const candidate={...row,id:this.editID||uuid()};
      const next=this.editID ? this.spans.map(s=>s.id===this.editID ? candidate:s) : [...this.spans,candidate];
      this.spans=validateDraftSpans({...this.template,language:this.language},next);this.editID=null;
    }
    remove(id) {this.spans=this.spans.filter(s=>s.id!==id);if(this.editID===id)this.cancelEdit();}
    importReference(ref) {
      validateReference(ref);
      if (!sameBinding(this.template,ref)) throw Error("다른 원본·구간의 정답입니다.");
      this.spans=ref.spans.map(clone);this.baseRevisionID=ref.revisionID;this.language=ref.language;
      this.reviewer=ref.reviewer||"";this.draftExposure=ref.draftExposure;this.editID=null;
    }
    draft() {return {version:2,...binding(this.template),templateRevisionID:this.template.revisionID,baseRevisionID:this.baseRevisionID,spans:this.spans.map(clone),language:this.language,reviewer:this.reviewer,draftExposure:this.draftExposure};}
    restore(raw) {
      if (typeof raw!=="string" || bytes(raw)>4000000) throw Error("보관된 초안 크기를 확인하세요.");
      const d=parseJSON(raw);
      if (!d || d.version!==2 || !sameBinding(this.template,d) || d.templateRevisionID!==this.template.revisionID || !uuidPattern.test(d.baseRevisionID) || !["und","ko","ja","en"].includes(d.language) || typeof d.reviewer!=="string" || bytes(d.reviewer)>256 || typeof d.draftExposure!=="boolean") throw Error("보관된 초안의 원본·버전·형식이 다릅니다.");
      const spans=validateDraftSpans({...this.template,language:d.language},d.spans);
      this.spans=spans;this.baseRevisionID=d.baseRevisionID;this.language=d.language;this.reviewer=d.reviewer;this.draftExposure=d.draftExposure;this.editID=null;
    }
    export(review) {if(this.editID)throw Error("편집 중인 구간을 먼저 저장하거나 취소하세요.");return exportReference({...this.template,revisionID:this.baseRevisionID,parentRevisionID:undefined},this.spans,review);}
    exported(ref) {this.baseRevisionID=ref.revisionID;}
  }
  function mount(doc,template,meta) {
    const $=id=>doc.getElementById(id),audio=$("audio"),session=new Session(template);
    const key="accuracy-review:v2:"+template.sourceSHA256+":"+template.segmentID+":"+template.revisionID;
    const message=e=>$("error").textContent=e.message||String(e);
    const resetReview=()=>["textReviewed","activityReviewed","timingReviewed"].forEach(id=>{$(id).checked=false;});
    const sync=()=>{session.language=$("language").value;session.reviewer=$("reviewer").value;session.draftExposure=$("draftExposure").checked;};
    function persist(){sync();try{localStorage.setItem(key,JSON.stringify(session.draft()));}catch{message(Error("이 브라우저에 초안을 보관하지 못했습니다. 검수 후 JSON을 저장하세요."));}}
    function fields(row){$("start").value=row.start;$("end").value=row.end;$("kind").value=row.kind;$("text").value=row.text;$("reason").value=row.reason;Array.from($("condition").options).forEach(o=>{o.selected=row.conditions.includes(o.value);});}
    function finishEdit(){session.cancelEdit();$("add").textContent="구간 추가";$("cancelEdit").hidden=true;}
    function draw(){
      $("rows").replaceChildren();session.spans.forEach(s=>{
        const tr=doc.createElement("tr"),time=doc.createElement("td"),body=doc.createElement("td"),controls=doc.createElement("td");
        tr.dataset.spanId=s.id;time.textContent=s.start.toFixed(3)+" → "+s.end.toFixed(3);
        body.textContent=({speech:"대사",nonspeech:"비발화",excluded:"제외"})[s.kind]+" · "+(s.text||s.reason);
        const edit=doc.createElement("button");edit.textContent="편집";edit.onclick=()=>{if(session.editID && session.editID!==s.id){message(Error("현재 구간의 편집을 저장하거나 취소하세요."));return;}fields(session.beginEdit(s.id));$("add").textContent="편집 저장";$("cancelEdit").hidden=false;};
        const remove=doc.createElement("button");remove.textContent="삭제";remove.onclick=()=>{if(session.editID){message(Error("편집을 저장하거나 취소한 뒤 삭제하세요."));return;}session.remove(s.id);resetReview();draw();persist();};
        controls.append(edit,remove);tr.append(time,body,controls);$("rows").append(tr);
      });
    }
    $("scope").textContent=template.sourceFile+" · 원본 "+template.sourceStart+"~"+template.sourceEnd+"초";
    $("rationale").textContent=meta.selectionRationale;
    const choice=(value,label)=>{const o=doc.createElement("option");o.value=value;o.textContent=label;$("channel").append(o);};
    choice("listen.wav","인식기에 전달되는 혼합 음성");meta.nativeChannelFiles.forEach((f,i)=>choice(f,"원본 채널 "+(i+1)));
    try{const raw=localStorage.getItem(key);if(raw!==null){try{session.restore(raw);}catch(e){try{localStorage.setItem(key+":rejected",raw);}catch{}message(Error("보관된 초안을 적용하지 않았습니다. 원본 초안은 보존했습니다. "+e.message));}}}catch{message(Error("초안 보관 기능을 사용할 수 없습니다."));}
    $("language").value=session.language;$("reviewer").value=session.reviewer;$("draftExposure").checked=session.draftExposure;
    fields({start:template.sourceStart,end:template.sourceEnd,kind:"speech",text:"",reason:"",conditions:["unknown"]});draw();
    const now=()=>Math.round((template.sourceStart+audio.currentTime)*1000)/1000;
    audio.ontimeupdate=()=>{$("clock").textContent="원본 "+now().toFixed(3)+"초";};
    $("channel").onchange=()=>{const position=audio.currentTime,rate=Number($("speed").value);audio.src=$("channel").value;audio.onloadedmetadata=()=>{audio.currentTime=position;audio.playbackRate=rate;};};
    $("speed").onchange=()=>{audio.playbackRate=Number($("speed").value);};
    $("captureStart").onclick=()=>{$("start").value=now();resetReview();};$("captureEnd").onclick=()=>{$("end").value=now();resetReview();};
    $("cancelEdit").onclick=()=>{finishEdit();fields({start:template.sourceStart,end:template.sourceEnd,kind:"speech",text:"",reason:"",conditions:["unknown"]});message("편집 취소됨 · 원래 구간 유지");};
    ["start","end","text","kind","reason","condition"].forEach(id=>{$(id).oninput=resetReview;});
    $("add").onclick=()=>{try{
      sync();if(!$("start").value.trim()||!$("end").value.trim())throw Error("시작·끝 시각을 입력하세요.");
      session.commit({start:Number($("start").value),end:Number($("end").value),kind:$("kind").value,text:$("text").value.trim(),reason:$("reason").value.trim(),conditions:Array.from($("condition").selectedOptions).map(o=>o.value)});
      finishEdit();resetReview();draw();persist();message("구간 저장됨 · 변경된 내용을 다시 검수하세요.");
    }catch(e){message(e);}};
    $("gaps").onclick=()=>{try{if(session.editID)throw Error("편집을 먼저 저장하거나 취소하세요.");session.spans=fillGaps({...template,language:session.language},session.spans);resetReview();draw();persist();}catch(e){message(e);}};
    $("language").onchange=()=>{resetReview();persist();};$("reviewer").oninput=()=>{resetReview();persist();};$("draftExposure").onchange=persist;
    $("save").onclick=()=>{try{
      sync();const result=session.export({reviewer:session.reviewer,language:session.language,textReviewed:$("textReviewed").checked,activityReviewed:$("activityReviewed").checked,timingReviewed:$("timingReviewed").checked,draftExposure:session.draftExposure});
      const a=doc.createElement("a"),url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)+"\n"],{type:"application/json"}));a.href=url;a.download=result.segmentID+".reference.json";a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
      session.exported(result);persist();message("새 검수 버전 다운로드 요청됨. 저장된 파일을 확인하고 평가에 사용하세요.");
    }catch(e){message(e);}};
    $("import").onclick=()=>{$("file").click();};$("file").onchange=async()=>{try{
      if(session.editID)throw Error("현재 편집을 먼저 저장하거나 취소하세요.");const file=$("file").files[0];if(!file||file.size>4000000)throw Error("정답 파일 크기를 확인하세요.");
      const ref=parseJSON(await file.text());session.importReference(ref);$("language").value=session.language;$("reviewer").value=session.reviewer;$("draftExposure").checked=session.draftExposure;resetReview();draw();persist();message("불러옴 · 다시 청취 검수한 뒤 새 버전으로 저장하세요.");
    }catch(e){message(e);}finally{$("file").value="";}};
    return session;
  }
  return {uuid,parseJSON,validateSpans,validateDraftSpans,validateReference,exportReference,fillGaps,Session,mount};
})();
if (typeof module!=="undefined") module.exports=AccuracyReview;
