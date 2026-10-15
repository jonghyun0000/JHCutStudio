#!/usr/bin/env python3
"""Offline human-review pages; never manufactures a reviewed reference."""
import json, shutil, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
def build(directory):
    directory=Path(directory).resolve()
    if not directory.is_relative_to(ROOT/"Artifacts"):
        raise ValueError("Review outputs must be in the run's Artifacts directory.")
    entries=json.loads((directory/"dataset-manifest.json").read_text())
    if not entries or len(entries)>100: raise ValueError("Invalid manifest")
    layout=(ROOT/"Scripts/accuracy-review.html").read_text()
    links=[]
    for item in entries:
        folder=directory/item["segmentID"]
        if folder.parent!=directory or folder.is_symlink(): raise ValueError("Invalid segment directory")
        template=json.loads((folder/"review-template.json").read_text())
        def embedded(data): return json.dumps(data,ensure_ascii=False).replace("<",r"\u003c").replace(">",r"\u003e").replace("&",r"\u0026")
        html=layout.replace("__TEMPLATE__",embedded(template)).replace("__METADATA__",embedded(item))
        for filename in ["review.html","accuracy-review.js"]:
            if (folder/filename).exists(): raise ValueError("Existing review artifact is preserved: "+filename)
        (folder/"review.html").write_text(html)
        shutil.copyfile(ROOT/"Scripts/accuracy-review.js",folder/"accuracy-review.js")
        links.append(f'- [{item["segmentID"]}](./{item["segmentID"]}/review.html) — {item["selectionRationale"]}')
    (directory/"REVIEW-START.md").write_text("# 실제 iPhone 정답 검수\n\n사람 검수가 아직 끝나지 않았으면 정확도 수치는 없습니다. 각 페이지를 브라우저에서 열어 원본 채널을 듣고 검수하세요. JSON 정답을 References/IPhone에 넣은 뒤 새 실행에서 평가합니다. 원본은 수정하지 않습니다.\n\n"+"\n".join(links)+"\n\n자세한 규칙: docs/ACCURACY-GUIDE-0.7.md\n")
    print("ACCURACY_REVIEW_READY",directory/"REVIEW-START.md")
if __name__=="__main__": build(sys.argv[1])
