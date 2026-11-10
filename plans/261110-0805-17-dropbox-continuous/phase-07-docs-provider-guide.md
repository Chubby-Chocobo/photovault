---
phase: 07
title: "Docs: spec, next free decision, extension doc, roadmap"
status: pending
priority: P3
size: S
human_effort: 0.5-1h
dependencies: [06]
touches:
  - docs/requirements/photovault-spec-v1.md
  - docs/requirements/roadmap.md
  - docs/decisions/
  - docs/architecture/continuous-source-extension.md
  - docs/architecture/system-architecture.md
  - docs/architecture/codebase-summary.md
  - README.md
  - site/public/privacy.html
acceptance:
  - grep -q "FR-125" docs/requirements/photovault-spec-v1.md
  - ls docs/decisions | grep -q "continuous-dropbox-source"
  - grep -q "continuous-dropbox-source" docs/decisions/README.md
  - grep -q "continuous-dropbox-source" docs/architecture/continuous-source-extension.md
  - test ! -e docs/architecture/adding-a-source-provider.md
---

# Phase 07: Docs

## Overview
This phase makes `docs/` true again. It updates the docs that branch `docs/future-continuous-sources` adds and that merge before this plan resumes: `docs/architecture/continuous-source-extension.md`, `docs/requirements/roadmap.md` and decision 0029 "Photos-only continuous source". It creates no parallel guide or roadmap. Size S: docs only.

## Context
- Decision numbers already taken:
  - 0028: split day by place (#27);
  - 0029: Photos-only continuous source (docs branch);
  - 0030: Drive import with `drive.readonly`.

  The new record takes the **next free number at resume time**. Check `docs/decisions/README.md` then; do not assume 0031.
- Spec §2 (in `docs/requirements/photovault-spec-v1.md`):
  - item 9 (line 32) says continuous sources other than Photos "sẽ thêm sau";
  - line 35 lists S3 and OneDrive under "Không làm", and continuous Dropbox as "để sau".
- The extension doc on the docs branch differs from this plan:
  - R8 allows a **Thử lại** button;
  - R10 gates the feed listing too;
  - R12 keeps the grant on removal.

## Requirements
1. Spec §4.13: add FR-125 to FR-130, in Vietnamese like the rest of the section. They follow the final plan, including the owner's answers to the two open questions in plan.md.
   - **FR-125 Nguồn liên tục Dropbox:**
     - Thêm và gỡ nguồn.
     - Một thư mục, mặc định `/Camera Uploads`; toàn bộ Dropbox sau một cảnh báo.
     - Không chồng lấn trong cùng tài khoản.
     - Token riêng `import-<sourceId>`; dọn token mồ côi khi khởi động (chỉ khi đọc được danh sách nguồn).
     - Gỡ nguồn theo lựa chọn của owner (mặc định: như huỷ import, FR-115, và xoá token).
   - **FR-126 Change feed:**
     - Mỗi nguồn có cursor; nguồn được đọc mỗi chu kỳ, cách nhau ít nhất 60 giây; timer 15 phút.
     - `reset` → liệt kê lại toàn bộ sau khi kiểm tra id thư mục gốc.
     - Gom trạng thái ròng theo thứ tự feed; một mục `deleted` luôn được giữ.
     - Áp dụng theo nhóm đường dẫn, compare-and-set; cursor ghi cùng giao dịch cuối.
     - Tải file chỉ khi luật mạng/nguồn điện cho phép upload; đọc feed thì không bị chặn.
   - **FR-127 Danh tính và phiên bản:**
     - Khoá `x:`.
     - Đổi tên, đổi hoa thường hay di chuyển không upload.
     - File sửa = asset mới sau 1 giờ ổn định, asset cũ đánh dấu xoá, không bao giờ ghi đè (theo câu trả lời của owner).
     - Một file khác chiếm đường dẫn của file cũ (safe-save, xoá rồi thêm) → dòng cũ bị xoá, file mới dùng lại dòng.
     - Tên trùng → `stem (n)` chung cho cả nhóm.
     - Hash lưu là hash của bytes đã đọc.
   - **FR-128 Xoá và an toàn:**
     - File xoá → `deleted_at`, backup giữ nguyên.
     - Hàng khác ở nguồn đang mở còn giữ cùng nội dung thì nhận lại asset, không upload lại; một import một lần đang upload quay về đọc. Huỷ import cũng giao lại như vậy.
     - Thư mục gốc đổi id, bị xoá hay đổi tên → `rootChanged`, không xoá gì.
     - Một lần đọc mà xoá quá max(50, 20 %) → `largeRemoval`:
       - nguồn chờ 10 phút giữa các lần thử;
       - xác nhận cho phép đúng một lần, tối đa số đã báo cộng 10 %;
       - mất xác nhận khi mở lại app hay đăng nhập lại thì hỏi lại.
   - **FR-129 Chờ ổn định:**
     - Nhóm file mới hoặc vừa sửa sau lần liệt kê đầu được đọc khi file mới nhất của nhóm đã thấy ≥ 1 giờ.
     - File lỗi được thử lại 24 giờ sau lần lỗi, và ngay sau listing đầy đủ hoặc khi đăng nhập lại.
   - **FR-130 Giao diện và giới hạn:**
     - "Nguồn liên tục" tách khỏi "Lần nhập"; mục "Nguồn" trên menu bar.
     - Trạng thái và lý do như phase 06; không gửi thông báo khi nguồn bị giữ.
     - Giới hạn:
       - Dropbox dừng khi mất quyền Photos;
       - trạng thái có thể nháy offline/watching khi chỉ phần tải hỏng;
       - sidecar có thể upload lại khi asset được nhận lại;
       - HEIC đổi sang JPG bị upload hai lần;
       - import một lần đã đóng không nhận lại asset;
       - xoá trong Photos không xếp lại hàng `duplicate` của Dropbox;
       - companion được giao lại có thể upload thêm một lần;
       - không hạ phiên bản sau khi đã thêm nguồn.

   Also:
   - FR-110: "Nguồn liên tục" lists Photos and the continuous sources.
   - §8.1 key line (`photovault-spec-v1.md:424`): continuous non-Photos sources also use `x:`; drop the `s:` sentence.
   - §2 item 9 and the "Không làm" line: continuous Dropbox moves from "để sau" to done. S3 and OneDrive stay out of 1.0 as sources, with a pointer to the roadmap.
   - §15: point to the roadmap instead of repeating it.
2. New decision `docs/decisions/<next free number>-continuous-dropbox-source.md`, copied from the plan.md Decisions: context, decision, consequences, review trigger. It says it supersedes 0029 (Photos-only continuous source) for Dropbox and supersedes part of 0024 (`x:` keys for continuous sources). Add a row to the decisions README, and a "superseded" line in 0029 and in 0024.
3. `docs/architecture/continuous-source-extension.md` (from the docs branch), updated in place:
   - Status: Dropbox implemented, with a link to the new decision.
   - The rules match the shipped behaviour:
     - R5: base-group batches and the per-group `stem (n)`;
     - R8: retry 24 h after the failure, no button;
     - R10: the feed listing is not gated;
     - R12: the owner's removal answer;
     - R14: a `deleted` entry is always kept;
     - a new rule for "another id at this path";
     - the brake allowance and cooldown in R3;
     - hand-over into an `importing` import and from `cancelImport` in R4.
   - The provider table keeps OneDrive, S3 and Flickr `[UNVERIFIED]`, with one paragraph on what a provider gets for free (brake, hand-over, settle window, daily retry, transfer gate).
   - Registration points: the `SourceKind` case, the `CloudImportServices` factory, `AppEnvironment.openContinuousSources`, the "Thêm nguồn" menu item, the Keychain item `import-<sourceId>`, the orphan sweep and factory reset.
   - Tests: a stub-transport adapter suite like `DropboxContinuousSourceTests`; engine behaviour is already covered by `FakeContinuousSource`.
4. `docs/requirements/roadmap.md` (from the docs branch): Dropbox moves from "Tương lai xa" to the release that ships it. OneDrive, S3 and Flickr stay there, each pointing to the extension doc.
5. `system-architecture.md`:
   - the feed stage at step 2, the brake and hand-over, and the reader seam and transfer gate in steps 3–4;
   - migration `continuous-sources`;
   - Keychain items and the sweep;
   - the privacy boundary: remote ids and paths live only in the database.

   `codebase-summary.md`: new files and test counts.
6. `README.md`: how to watch a Dropbox folder, what the statuses mean, the limits listed in FR-130, and "do not downgrade after adding a source". `site/public/privacy.html`: continuous Dropbox sources read the chosen folder regularly, read-only, and download only under the network and power rules.

## Risks and rollback
- Text conflicts with feat/27 and the docs branch in the spec, the architecture doc and the decisions README. Merge them first, then edit.
- Rollback: revert the docs commit.
