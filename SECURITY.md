# Security policy

JH CUT Studio is currently a pre-release macOS application. There is no published supported release series or guaranteed response time yet. Reports affecting the latest source and development build are welcome. Older development snapshots do not have a separate security maintenance commitment.

## Reporting a vulnerability

Check the repository's [Security page](https://github.com/jonghyun0000/JHCutStudio/security). If **Report a vulnerability** is available, submit the report through that private form.

Private vulnerability reporting was disabled when checked on 2026-10-14. If the private form is unavailable and no private contact is listed there, open an issue titled **Request for a private security contact** containing only a request for a confidential channel. Do not include the vulnerability, exploit steps, credentials, private media or attachments in that public request. Wait for a private channel before sending sensitive details. This fallback follows [GitHub's private reporting guidance](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).

In a private report, include the affected version or commit, macOS and chip, the impact, minimal reproduction steps, and a small safe proof of concept when possible. Relevant areas include project-file parsing, unexpected filesystem access, output publication, path traversal or symbolic links, model downloads, bundled runtime execution, and exposure of private media or transcripts.

Use disposable files and synthetic or redistributable media. Do not test against another person's data, upload private recordings, or place secrets in logs. If a credential has already been exposed, revoke or rotate it through its provider; removing the visible file does not revoke it.

## Handling and disclosure

The maintainer will assess reproducibility, affected versions and remediation, then coordinate disclosure through the private channel. Please allow time for a fix and distribution before publishing details. No response deadline or bounty program is promised.

The local editor's transcription path processes audio on the Mac. Model installation downloads files and translation language packs have separate requirements. These design properties do not replace a security review. A successful build, ad-hoc signature or local automated test is not a signed-release security guarantee.

## 한국어 안내

취약점 세부 내용은 공개 이슈에 올리지 마세요. 저장소 Security 화면에 비공개 제보 버튼이 있으면 사용해 주세요. 없으면 **Request for a private security contact**라는 제목으로 비공개 연락 방법만 요청하고, 답변을 받은 뒤 민감한 정보를 전달해 주세요. 개인 영상·자막·인증 정보는 공개 첨부하지 마세요.
