---
phase: 07
title: "Docs: spec, decision 0029, provider guide, roadmap"
status: pending
priority: P3
size: S
human_effort: 0.5-1h
dependencies: [06]
touches:
  - docs/requirements/photovault-spec-v1.md
  - docs/decisions/0029-continuous-dropbox-source.md
  - docs/decisions/0024-multiple-sources-and-folder-import.md
  - docs/decisions/README.md
  - docs/architecture/system-architecture.md
  - docs/architecture/codebase-summary.md
  - docs/architecture/adding-a-source-provider.md
  - README.md
  - site/public/privacy.html
acceptance:
  - test -f docs/decisions/0029-continuous-dropbox-source.md
  - test -f docs/architecture/adding-a-source-provider.md
  - grep -q "FR-125" docs/requirements/photovault-spec-v1.md
  - grep -q "0029-continuous-dropbox-source" docs/decisions/README.md
---

# Phase 07: Docs

## Overview
This phase makes `docs/` true again and records the provider mechanism. Size S: docs only.

## Requirements
1. Spec §4.13: add FR-125 to FR-130, in Vietnamese like the rest of the section.
   - **FR-125 Nguồn liên tục Dropbox:**
     - Thêm và gỡ nguồn.
     - Một thư mục, mặc định `/Camera Uploads`; toàn bộ Dropbox sau một cảnh báo.
     - Không chồng lấn trong cùng tài khoản.
     - Token riêng `import-<sourceId>`; dọn token mồ côi khi khởi động.
     - Gỡ nguồn như huỷ import (FR-115): asset có job chưa xong bị coi như đã xoá, asset đã sao lưu đủ vẫn sống, token bị xoá.
   - **FR-126 Change feed:**
     - Mỗi nguồn có cursor; nguồn được đọc mỗi chu kỳ, cách nhau ít nhất 60 giây; timer 15 phút.
     - `reset` → liệt kê lại toàn bộ sau khi kiểm tra id thư mục gốc.
     - Áp dụng theo thứ tự từng đường dẫn, compare-and-set; cursor ghi cùng giao dịch cuối.
     - Tải file chỉ khi luật mạng/nguồn điện cho phép upload.
   - **FR-127 Danh tính và phiên bản:**
     - Khoá `x:`.
     - Đổi tên, đổi hoa thường hay di chuyển không upload.
     - File sửa = asset mới sau 1 giờ ổn định; asset cũ đánh dấu xoá; không bao giờ ghi đè.
     - Tên trùng → `stem (n).ext`.
     - Hash lưu là hash của bytes đã đọc.
   - **FR-128 Xoá và an toàn:**
     - File xoá → `deleted_at`, backup giữ nguyên.
     - Hàng khác còn giữ cùng nội dung thì nhận lại asset, không upload lại.
     - Thư mục gốc đổi id, bị xoá hay đổi tên → `rootChanged`, không xoá gì.
     - Một lần đọc mà xoá quá max(50, 20 %) → `largeRemoval`, chờ owner xác nhận.
   - **FR-129 Chờ ổn định:**
     - Nhóm file mới hoặc vừa sửa sau lần liệt kê đầu được đọc khi file mới nhất của nhóm đã thấy ≥ 1 giờ.
     - File lỗi được thử lại mỗi ngày.
   - **FR-130 Giao diện và giới hạn:**
     - "Nguồn liên tục" tách khỏi "Lần nhập"; mục "Nguồn" trên menu bar.
     - Trạng thái và lý do như phase 06.
     - Giới hạn: Dropbox dừng khi mất quyền Photos; trạng thái có thể nháy offline/watching khi chỉ phần tải hỏng; sidecar có thể upload lại khi asset được nhận lại; HEIC đổi sang JPG bị upload hai lần; import một lần đã đóng không nhận lại asset; xoá trong Photos không xếp lại hàng `duplicate` của Dropbox.

   Also:
   - FR-110: "Nguồn liên tục" lists Photos and the continuous sources.
   - §8.1 key line (`photovault-spec-v1.md:424`): continuous non-Photos sources also use `x:`; drop the `s:` sentence.
   - §15: replace the continuous-Dropbox bullet with roadmap bullets for OneDrive, S3 (as a source) and Flickr, each pointing to the provider guide.
2. Decision 0029, copied from the plan.md Decisions: context, decision, consequences, review trigger. Add a row to the decisions README. In 0024, add "superseded in part by 0029 (`x:` keys for continuous sources)".
3. `docs/architecture/adding-a-source-provider.md` (short):
   - The contract and its rules:
     - stable ids; `contentHash` changes exactly with the bytes, and `inspect` returns the hash of the bytes read;
     - net-state compaction in feed order; `isComplete`;
     - pagination and cursor reset inside the adapter;
     - root identity check before any complete listing, and `rootChanged` instead of removals;
     - `SourceError` mapping; no paths or ids in logs.
   - Engine guarantees a provider gets for free: the brake, hand-over, settle window, daily retry and transfer gate.
   - Registration points:
     - a `SourceKind` case;
     - the `CloudImportServices` factory;
     - `AppEnvironment.openContinuousSources`;
     - the "Thêm nguồn" menu item;
     - the Keychain item `import-<sourceId>`, the orphan sweep and factory reset.
   - Tests: a stub-transport adapter suite like `DropboxContinuousSourceTests`. Engine behaviour is already covered by `FakeContinuousSource`.
   - Provider table, all marked `[UNVERIFIED]`:

     | Provider | Change feed | Content hash | Root guard | Auth and notes |
     |---|---|---|---|---|
     | OneDrive | Graph `delta`, `@odata.deltaLink` as cursor; deleted facet → `.item`; `410 resyncRequired` → complete listing | `cTag` | root item id | PKCE loopback with an Azure app, `Files.Read offline_access` |
     | S3-compatible | none: a `ListObjectsV2` full listing every poll → `isComplete` | ETag | bucket + prefix | SigV4 read-only key in the Keychain. The key is the id, so a rename is remove + add, which revives by `x:` key. The brake matters most here. Use a longer poll interval for request cost. |
     | Flickr | `flickr.photos.recentlyUpdated` with `min_date` as cursor, plus a daily complete listing for deletions | `originalsecret` + `originalformat` (`lastupdate` also moves on metadata edits) | account id | OAuth 1.0a HMAC-SHA1, with a consumer secret shipped in the app; download `url_o` |
4. `system-architecture.md`:
   - the feed stage at step 2, the brake and hand-over, and the reader seam and transfer gate in steps 3–4;
   - migration `continuous-sources`;
   - Keychain items and the sweep;
   - the privacy boundary: remote ids and paths live only in the database.

   `codebase-summary.md`: new files and test counts.
5. `README.md`: how to watch a Dropbox folder, what the statuses mean, the limits listed in FR-130, and "do not downgrade after adding a source". `site/public/privacy.html`: continuous Dropbox sources read the chosen folder regularly, read-only, and download only under the network and power rules.

## Risks and rollback
- Text conflicts with feat/27 in the spec, the architecture doc and the decisions README. Decision 0028 belongs to #27.
- Rollback: revert the docs commit.
