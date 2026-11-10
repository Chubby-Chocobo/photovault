# Nguồn liên tục: cơ chế thêm nguồn

- **Trạng thái:** Thiết kế, chưa implement. Không có dòng code nào của nguồn liên tục trong nhánh phát hành.
- **Ngày:** 2026-11-10
- **Vai trò:** tài liệu hướng dẫn duy nhất để thêm nhà cung cấp (không có file `adding-a-source-provider.md` riêng).
- **Kế hoạch:** `plans/261110-0805-17-dropbox-continuous/` trên nhánh `feat/17-dropbox-continuous` (tạm dừng).
- **Liên quan:** quyết định [0024](../decisions/0024-multiple-sources-and-folder-import.md), [0026](../decisions/0026-cloud-folder-imports.md), [0029](../decisions/0029-photos-only-continuous-source.md); spec FR-110, FR-115, FR-121, FR-124; issue #17 (tạm dừng)

Tài liệu này mô tả cách thêm một nguồn liên tục (một thư mục hoặc tài khoản được theo dõi mãi, không chỉ nhập một lần) mà không làm lại pipeline. Mọi quy tắc trong mục "Quy tắc an toàn" là yêu cầu bắt buộc với mỗi nhà cung cấp, rút từ bản audit của kế hoạch Dropbox.

## Tóm tắt

Photos là nguồn liên tục duy nhất. Dropbox và thư mục Google Drive chỉ nhập một lần. Khi có nhu cầu, một nhà cung cấp mới được thêm bằng một adapter triển khai `ContinuousSource`; phần còn lại (bảng `import_item`, pipeline nhập, xuất, Keychain, UI) dùng chung.

## Vì sao hiện chỉ có Photos

- Owner quyết định ngày 2026-11-10: Photos là nguồn liên tục duy nhất ([0029](../decisions/0029-photos-only-continuous-source.md)).
- Kế hoạch Dropbox liên tục và bản audit (2 Critical, 8 Important) cho thấy rủi ro thật: đổi tên hoặc xoá thư mục gốc có thể đánh dấu xoá cả thư viện; một file có thể bị xoá khỏi backup khi bản sao của nó vẫn còn ở nguồn khác. Các lỗi này phải được chặn trước khi nguồn liên tục nào được phát hành.
- Mỗi file đổi nội dung là một bản sao mới trên đích. Chi phí lưu trữ tăng mà owner chưa chấp nhận cho mọi thư mục.

## Hợp đồng `ContinuousSource` (đề xuất)

Mã dưới đây là đề xuất, chưa có trong `Sources/`. Tên khớp với kế hoạch Dropbox (phase 01).

```swift
public protocol ContinuousSource: ContentSource {
    /// Throws SourceError.unavailable, or rootChanged when the root folder is not the one added.
    func probe() async throws
    /// Net change since `cursor` (nil = first listing). Cursor resets are handled inside the adapter.
    func changes(since cursor: String?) async throws -> SourceChanges
    /// Reads the file by its remote id and returns the hash of the bytes it actually read.
    func inspect(remoteId: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile
}

public struct SourceChanges: Sendable {
    public var files: [RemoteFile]          // new or changed, net state, in feed order per path
    public var removals: [RemoteRemoval]
    public var isComplete: Bool             // true: anything known and not listed is gone
    public var cursor: String?              // opaque; stored with the last batch
}

public struct RemoteFile: Hashable, Sendable {
    public var remoteId: String             // stable across renames and moves
    public var relativePath: String         // NFC, "/"-separated, under the root
    public var pathKey: String              // provider key used by removals, compared exactly
    public var uti: String
    public var sizeBytes: Int64
    public var contentHash: String?         // provider value; changes when the bytes change
    public var creationDate: Date?
    public var modificationDate: Date?
}

public enum RemoteRemoval: Hashable, Sendable {
    case item(remoteId: String)             // provider reports the id (OneDrive, Google Drive)
    case tree(pathKey: String)              // provider reports only the path (Dropbox)
}
```

Rules that every adapter follows:

| Điểm | Quy định |
|---|---|
| Cursor | Opaque. The adapter pages until the provider says there is no more, then returns the cursor of that position. |
| Reset | A cursor the provider no longer accepts (reset, expired, not found) makes the adapter run a full listing itself and return `isComplete = true`. The engine never sees the reset. |
| `isComplete` | `true` only for a full listing. Then anything known and not listed is removed (subject to the brake, R3). |
| Net state | Entries of one delta are compacted per path in feed order before return (a file listed and then deleted in the same delta is not returned). |
| Hash | `contentHash` is only a change signal. The hash stored for an asset is the hash of the bytes `inspect` read (R6). |
| Paths | Relative to the root; NFC; no `..`. Folding for comparison is done in Swift, not with SQLite `lower()` (ASCII only). |
| Root | The adapter stores the root's provider id at add time and checks it before every full listing (R1). |

## Cách nối vào pipeline nhập

| Bước | Nội dung | Điểm trong code hiện có |
|---|---|---|
| Định danh | Asset dùng khoá `x:<sha256 của file primary>`, như nhập một lần. Không dùng `s:` như spec §8 đã dự kiến. Mỗi dòng `import_item` là một "ô đường dẫn" của nguồn: `rel_path` cố định từ lần đầu thấy; id, đường dẫn từ nhà cung cấp và hash được lưu thêm trong bảng (cột nullable, thêm bằng migration mới). | `Sources/PhotoVaultCore/Models/AssetKey.swift:11`, `:20`; `Sources/PhotoVaultCore/Entities/SourceRecords.swift:61` |
| Feed | Một stage mới chạy ở bước `.changes` của chu kỳ, sau theo dõi thay đổi của Photos; tối đa một lần mỗi 60 giây cho mỗi nguồn. Stage nhập hiện chỉ lấy nguồn `kind.isImport`, nên stage mới cần lọc riêng. | `Sources/PhotoVaultEngine/ImportStage.swift:25`; `Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift` |
| Planner | Hàm thuần trong Core: so `SourceChanges` với các dòng đã biết, trả về danh sách hành động (`insert`, `reuse`, `returned`, `moved`, `changed`, `removed`). | Mới, trong `Sources/PhotoVaultCore/Rules/` |
| Áp dụng | Theo thứ tự cố định, theo lô khoảng 500 hành động, chỉ tách giữa các đường dẫn khác nhau. Mỗi cập nhật kiểm tra lại `(source_id, rel_path, remote_id)` (compare-and-set). Lô cuối ghi cùng transaction cho `cursor`, `listed_at`. | Mới, trong Engine; dùng `ImportItemRepository` |
| Crash | Mọi hành động là idempotent: thêm theo `remote_id`, so hash, xoá theo khoá. Feed gửi lại sau crash (trước khi cursor được ghi) không tạo dòng, asset hay upload trùng. | Cùng mẫu với token thay đổi của Photos |
| Nhập | Dòng đến lượt đọc: `inspect(remoteId)` → sha256 → dedupe (khoá `x:`, sha256 của resource, dấu vân tay) → `x:` asset → `AssetFinalizer`. Pipeline này giống nhập một lần. | `Sources/PhotoVaultEngine/ImportStage+Ingest.swift:11`, `:151` |
| Xuất | Upload đọc byte qua `exportResource` theo id. Kiểm tra hash cũ vẫn giữ. | `Sources/PhotoVaultEngine/ExportWorker+SourceFailures.swift:8`, `:25` |

## Quy tắc an toàn bắt buộc

Mỗi quy tắc có kịch bản mà nó chặn. Nhà cung cấp nào không đáp ứng thì không được bật.

| Mã | Quy tắc | Kịch bản bị chặn |
|---|---|---|
| R1 | Lưu id của thư mục gốc khi thêm nguồn (`SourceConfig`, trường `remoteRootId`; tài khoản Dropbox toàn bộ không có id). Trước mỗi listing đầy đủ và khi `probe()`, id phải khớp. Không khớp hoặc không có gốc → lỗi `SourceError.rootChanged`, nguồn `offline` với lý do `rootChanged`, không commit gì. | Đổi tên `/Camera Uploads` rồi điện thoại tạo lại thư mục cùng tên: cursor báo `reset`, listing đầy đủ của thư mục rỗng đánh dấu mọi asset đã xoá. |
| R2 | Một mục `deleted` trùng hoặc cao hơn thư mục gốc không bao giờ thành `.tree`; nó là lỗi `rootChanged`, cursor không commit. | Xoá thư mục gốc: `.tree(root)` xoá mọi dòng của nguồn. |
| R3 | Bộ chặn xoá hàng loạt: nếu một feed có số `removed` vượt max(50 dòng, 20 % số dòng đang sống), không commit gì. Nguồn `offline` với lý do `largeRemoval` ("cần xác nhận"). Sau khi chặn, nguồn chờ 10 phút rồi mới thử lại (không lập lại cả delta ở mỗi lần poll). Lần chặn lưu số dòng bị xoá. Owner bấm **Xác nhận** (chỉ khi lý do là `largeRemoval`): lệnh chỉ xoá thời gian chờ và cho đúng một feed kế tiếp được áp dụng, với tối đa số dòng đã lưu cộng 10 %. Hạn mức chỉ nằm trong bộ nhớ: mở lại app hoặc đăng nhập lại thì mất, và bộ chặn hỏi lại, nên nguồn không bao giờ bị kẹt. Feed thứ hai vượt ngưỡng lại bị chặn. | Lỗi của nhà cung cấp hoặc thay đổi lớn không lường trước. Lỗi trong R1–R2 cũng được chặn ở đây. Nếu chính lệnh xác nhận xoá luôn hạn mức thì feed kế tiếp lại bị chặn và nguồn bị kẹt cho tới khi **Gỡ**. |
| R4 | Khi asset bị retire, mọi dòng khác còn giữ byte của nó (`imported` không phải primary, `duplicate`, ở nguồn đang mở) được chuyển giao (`AssetHandover`). Giới hạn: chỉ chạy khi asset đang sống, thuộc nguồn này và `local_id` là của dòng này; chỉ chuyển giao cho dòng ở nguồn liên tục đang mở hoặc nhập một lần đang mở. Nhập một lần đã đóng không được chuyển giao (không có gì nhập lại các dòng đó; chạy nhập lại sẽ gắn lại asset). Dòng được chuyển giao về `pending` với nhóm có hậu tố và `seen_at = NULL`; lần ingest sau gắn lại K (không upload lại nếu job đã xong) hoặc tạo asset mới. Một companion được chuyển giao (JPEG còn lại khi RAW bị xoá) thành asset `x:` riêng, có thể được upload thêm một lần dưới tên riêng, không bao giờ mất. Xoá ảnh trong Photos không đưa lại dòng `duplicate` của nguồn liên tục vào hàng đợi (giới hạn đã ghi nhận). | Cùng một ảnh nằm ở hai thư mục theo dõi: xoá một bản làm mất backup của bản còn lại. RAW bị xoá, JPEG giữ lại: JPEG bị huỷ job. Sao chép sang thư mục nguồn khác rồi xoá nguồn gốc. |
| R5 | Thứ tự áp dụng: `removed` → `changed` → `moved` → `returned` → `reuse` → `insert`; sắp theo `rel_path`. Chọn tên trống `stem (n).ext` trong transaction, dựa trên các dòng đã có (so theo khoá đã gấp). | Hành động `reuse(p)` và `removed(p)` rơi vào hai lô khác nhau: file mới không bao giờ được đọc. `stem (2).jpg` đã có dòng: khoá chính bị vi phạm và feed lỗi lặp lại. |
| R6 | `inspect` trả về hash của byte thực sự đọc (Dropbox: SHA-256 của chuỗi SHA-256 các khối 4 MiB, tính khi stream). Dòng lưu hash này, không lưu hash của feed. | File đổi giữa feed và lúc đọc: asset mới bị retire ngay ở feed sau, tải lại, rồi sống lại. |
| R7 | Cửa sổ chờ theo nhóm: nhóm (RAW+JPEG, Live Photo) sẵn sàng khi thành viên mới nhất đã chờ đủ (mặc định 1 giờ), quyết định cho cả nhóm. | Cặp đến ở hai lần kiểm tra khác nhau bị tách thành hai asset. |
| R8 | Dòng `failed` của nguồn liên tục được đưa về `pending` theo lịch: ở lần kiểm tra đầu tiên sau khi mở app, rồi mỗi 24 giờ, sau listing đầy đủ và khi đăng nhập lại. Không có nút **Thử lại** (đã bị loại). Dòng hiện "N file chưa đọc được · thử lại mỗi ngày". | Sau khi FR-124 bỏ cuộc, ảnh không bao giờ được backup và không ai biết (nguồn liên tục không có "nhập lại"; một hash không đổi không sinh hành động nào). |
| R9 | File đổi nội dung là phiên bản mới: không ghi đè. Dòng về `pending` với nhóm riêng và `seen_at = now`, nên chờ cửa sổ R7. Chỉ phiên bản có sau cửa sổ được đọc. Nếu dòng là primary của asset đang sống của nguồn này, asset đó bị retire (`deleted_at`, `local_id` đổi thành `<cũ>#<16 hex>`) và R4 áp dụng; companion đã đổi thành asset riêng, cặp cũ vẫn sống. Trình chọn thư mục mở ở `/Camera Uploads` khi có; theo dõi cả Dropbox cần xác nhận cảnh báo rằng mỗi lần sửa thêm một bản sao. Ngưỡng hỏi owner khi nhiều file đổi cùng lúc chưa được chọn (xem câu hỏi mở). | Ghi đè file gốc làm mất bản trước. Các công cụ ghi metadata tại chỗ (Lightroom, digiKam) làm archive lớn lên mà không cảnh báo. |
| R10 | Cổng `TransferGate.allowsNow` (mạng, `pauseOnExpensiveNetwork`, `allUploadsOnlyOnACPower`), cùng luật với upload, áp cho việc đọc file và tải xuống của nguồn liên tục: khi cổng đóng, nhập liên tục không đọc gì và asset liên tục không nằm trong danh sách xuất. Việc liệt kê feed vẫn chạy (vài request nhỏ). Nhập một lần giữ hành vi 0.4.0. | Cả thư viện Dropbox được tải hai lần trong nền khi đang dùng 4G hoặc pin. Hiện `ImportStage` không kiểm tra điều này. |
| R11 | Id migration không đánh số (`continuous-sources`), đăng ký sau migration cuối của nhánh gốc khi merge, và không đổi tên khi bất kỳ bản build nào đã chạy nó. `Store.open` từ chối schema mới hơn. Rollback: sau khi đã dùng, hạ phiên bản làm app không mở được dữ liệu. | Đổi tên migration làm lặp `ALTER TABLE ADD COLUMN` (lỗi "duplicate column"). Bản cũ đọc `state = 'removed'` làm hỏng `SourceRepository.fetchAll`, kéo theo cả backup Photos. |
| R12 | Gỡ nguồn = huỷ nhập (FR-115), theo từng asset: (1) dòng chưa xử lý thành `cancelled`; (2) asset có job pending, đang upload hoặc deferred được retire qua `AssetHandover`, job chưa xong bị huỷ, nơi khác giữ bản sẽ nhận chuyển giao; (3) asset đã backup đủ vẫn sống, các dòng của nguồn mở khác giữ chúng đi về `pending` và nhận chuyển giao; (4) nguồn thành `cancelled`, cursor xoá, adapter gỡ đăng ký, holds xoá, và app xoá grant `import-<id>`. Đích thêm sau không nhận các asset không ai nhận chuyển giao (`resourceMissing`). Thêm lại cùng thư mục thì nhận chuyển giao hoặc gắn lại mà không upload lại bản gốc. Lý do xoá grant: owner đã rút quyền truy cập của PhotoVault. Đây là quyết định của lead, không phải của owner; giá phải trả là các lần bỏ qua `resourceMissing` nhìn thấy được. | Giữ grant mà không có dòng nguồn thì grant thành mồ côi; xoá asset của nguồn khác còn giữ bản thì mất file. |
| R13 | Khớp đường dẫn: so khớp chính xác theo khoá; tiền tố phải là `key + "/"` (không phải `/a/bc` khớp `/a/b`). Chuẩn hoá hoa thường trong Swift. | Xoá `/Photos/x` làm mất `/photos/x`. Tên tiếng Việt khác hoa thường (`ẢNH.jpg`, `ảnh.jpg`) bị coi là một file. |
| R14 | Adapter trả về trạng thái ròng, sắp theo thứ tự feed cho mỗi đường dẫn. | File được liệt kê rồi bị xoá cùng thư mục trong một delta vẫn sống: dòng cũ và file xuất lỗi về sau. |
| R15 | Log, Hoạt động gần đây và sidecar không chứa tên file, đường dẫn, id nhà cung cấp, email (FR-123). | Lộ thông tin riêng tư qua log. |

Mỗi quy tắc phải có test trước khi bật nhà cung cấp: R1–R3 với thư mục gốc đổi tên và xoá (có và không có `reset`), R4 với bốn tình huống (cùng ảnh hai thư mục, RAW xoá, JPEG giữ, sao chép chéo nguồn), R5 với hơn 500 hành động và một dòng `stem (2)` có sẵn, R6 với byte đổi giữa feed và đọc, R7 với cặp đến ở hai lần kiểm tra.

## Chạy và tần suất

| Mục | Quy định |
|---|---|
| Kiểm tra feed | Tối đa một lần mỗi 60 giây cho mỗi nguồn; lần kích hoạt thủ công bỏ qua khoảng chờ. |
| Chu kỳ | Mỗi 15 phút khi có nguồn liên tục đang mở (đề xuất; xem câu hỏi mở). Chu kỳ dựa trên `ready` của snapshot, không dựa trên số dòng `pending` (dòng đang chờ 1 giờ không kích hoạt chu kỳ đầy đủ). |
| Cửa sổ chờ | 1 giờ cho file tìm thấy sau listing đầu; listing đầu nhập ngay theo nhịp của nhập một lần. |
| Mạng và nguồn điện | Theo R10. |
| Đăng nhập lại | Thu hồi grant: nguồn `offline` với lý do `signInRequired`, chỉ nguồn đó bị giữ. Đăng nhập lại cùng tài khoản dùng lại dòng và grant, tiếp tục ở chu kỳ sau (FR-121). |
| Thiếu chỗ trống | Lý do `diskFull`, hiển thị "Chờ chỗ trống" (FR-124). |
| Mất quyền Photos | Chu kỳ dừng cả ở đây, nên nguồn liên tục cũng dừng. Giới hạn đã chấp nhận, ghi trong README. |
| Lỗi tạm thời | `busy` và `unavailable` giữ nguồn trong thời gian ngắn; lỗi kéo dài thì giữ theo lý do. Lý do giữ nằm trong bộ nhớ, không cần bảng mới. |

## Giao diện

- Settings › Nguồn gồm hai phần tách biệt: **Nguồn liên tục** (Photos luôn đứng đầu, rồi mỗi nguồn đang theo dõi) và **Lần nhập** (nhập một lần).
- Mỗi nguồn liên tục có chấm trạng thái, tên, tài khoản và các trạng thái: Đang theo dõi · kiểm tra lần cuối …; Đang đọc N file mới; Không kết nối được; Cần đăng nhập lại (kèm nút); Chờ chỗ trống; Cần xác nhận (R3).
- Hành động: **Thêm nguồn…** (với nhà cung cấp chưa cấu hình khoá thì bị vô hiệu), **Gỡ…** (có xác nhận, theo R12), **Đăng nhập lại**, **Xác nhận** (R3). Không có nút Thử lại; thử lại theo lịch ở R8.
- Menu bar chỉ hiện mục "Nguồn" khi có nguồn liên tục ngoài Photos.

## Bảng sơ phác từng nhà cung cấp

Toàn bảng là `[UNVERIFIED]` trừ khi ghi khác: chưa kiểm tra tài liệu hoặc hành vi thật. Owner E2E hoặc spike phải xác nhận trước khi viết adapter.

| Nhà cung cấp | Xác thực | Phát hiện thay đổi | Định danh | Rủi ro chính |
|---|---|---|---|---|
| Dropbox | OAuth PKCE (đã có, FR-120): `files.metadata.read`, `files.content.read`, `account_info.read`. Chỉ đọc. | `files/list_folder` rồi `files/list_folder/continue` tới khi `has_more = false`. Cursor gắn với đường dẫn. | `id:` của file (`DropboxListEntry.id`). Id thư mục gốc từ metadata khi thêm nguồn. | Đổi tên gốc: `path/not_found` hoặc `reset`, và có thể thấy thư mục rỗng cùng tên (R1). Mục `deleted` chỉ có `path_lower`, không có id: dùng `.tree`. Hash nội dung là SHA-256 trên các khối, không phải SHA-256 của file: R6. HEIC có giữ nguyên byte không (owner E2E). |
| OneDrive | Microsoft Graph OAuth PKCE; scope đọc file `[UNVERIFIED]`. | Delta: theo `@odata.nextLink`, lưu `@odata.deltaLink`. Mã `410` / `resyncRequired` buộc listing đầy đủ. | Id item của Graph. Xoá có id: `.item`. | Delta cho thư mục không phải gốc có thể bị giới hạn trên tài khoản cá nhân `[UNVERIFIED]`. `cTag` và `eTag` khác nhau về ý nghĩa. |
| Google Drive (tài khoản khác) | OAuth Desktop, Picker với `drive.file` (`Sources/PhotoVaultDrive/GooglePickerFlow.swift:30`). | `changes.list` với `pageToken`, lấy `startPageToken` ban đầu. | Id file Drive. `md5Checksum` là tín hiệu thay đổi. Xoá có id: `.item`. | `drive.file` chỉ thấy file mà app đã được chọn qua Picker. Thư mục do tài khoản khác tạo có thể không thấy file mới: cần spike [VERIFY]. Scope `drive.readonly` là scope hạn chế, cần duyệt của Google. |
| S3-compatible | Access key chỉ đọc (không có quyền xoá, theo spec §15), lưu trong Keychain. SigV4. | `ListObjectsV2` không có feed thay đổi: mỗi lần kiểm tra là một listing đầy đủ, so `ETag`. | Khoá đối tượng. Xoá = vắng mặt, nên mọi lần đều là `isComplete`. | Bộ chặn R3 là bắt buộc. `ETag` của multipart không phải MD5 của byte. Listing thường xuyên tốn request. File lớn phải tải để tính sha256 (R6). |
| Flickr | OAuth 1.0a, cần API key và secret của owner. | `flickr.photos.recentlyUpdated` cho thay đổi; không có feed xoá, nên listing đầy đủ hằng ngày (`flickr.people.getPhotos`). | Id ảnh. | Thay đổi chỉ là metadata làm ảnh xuất hiện lại. Giới hạn tốc độ. Chọn kích thước gốc cho upload `[UNVERIFIED]`. |
| WebDAV, Immich (spec §15) | Basic / token (WebDAV); API key (Immich). | WebDAV: `PROPFIND` đầy đủ, so `getetag`. Immich: chưa rõ `[UNVERIFIED]`. | Đường dẫn (WebDAV); id asset (Immich). | Không có feed thay đổi chuẩn: coi như S3. |

## Đã có để tái dùng

| Thành phần | Vị trí | Dùng cho |
|---|---|---|
| `ContentSource`, `FolderImportSource`, `FileMetadataReading` | `Sources/PhotoVaultCore/Protocols/ContentSource.swift:19`, `:83`, `:91` | Nền của `ContinuousSource` |
| `SourceKind` (`dropbox`, `googleDrive`, `localFolder`), `SourceMode` (`continuous`, `oneTime`) | `Sources/PhotoVaultCore/Models/SourceModels.swift:41`, `:67` | Thêm kind cho nhà cung cấp mới |
| `SourceStatus` (`isOpen`) | `Sources/PhotoVaultCore/Models/SourceModels.swift:72` | Trạng thái nguồn liên tục (`watching`, `offline`, `cancelled`) |
| `CloudTokenAccount.importGrant` (`import-<id>`) | `Sources/PhotoVaultCore/Models/SourceModels.swift:54` | Grant riêng cho mỗi nguồn |
| `ImportLocator` (`<sourceId>/<đường dẫn>`) | `Sources/PhotoVaultCore/Models/SourceModels.swift:85` | `localId` của asset |
| `SourceConfig` (`remoteItems`, `sidecarName`) | `Sources/PhotoVaultCore/Entities/SourceRecords.swift:4` | Thêm `remoteRootId` |
| `SourceRecord`, `ImportItem`, `ImportItemState` | `Sources/PhotoVaultCore/Entities/SourceRecords.swift:24`, `:56`, `:61` | Dòng nguồn và dòng file |
| `AssetKey` (`x:`) | `Sources/PhotoVaultCore/Models/AssetKey.swift:11`, `:20` | Khoá asset |
| `SourceError` | `Sources/PhotoVaultCore/Errors/SourceError.swift:4` | Thêm `rootChanged` |
| Phân loại lỗi (`fileMissing`, `fileChanged` → `resourceMissing`) | `Sources/PhotoVaultCore/Errors/ErrorClassifier.swift:61` | Lỗi xuất |
| `SourceRegistry` (actor, `add`, `remove`, `folder(for:)`) | `Sources/PhotoVaultEngine/SourceRegistry.swift:5`, `:12`, `:13` | Đăng ký adapter |
| `ImportStage` (`run`, `advance`) | `Sources/PhotoVaultEngine/ImportStage.swift:11`, `:23`, `:43` | Pipeline đọc, giữ nguyên |
| `ingestBatch`, `nextGroups`, `commitGroup` | `Sources/PhotoVaultEngine/ImportStage+Ingest.swift:11`, `:54`, `:151` | Đọc và commit nhóm |
| `finishWhenDone` | `Sources/PhotoVaultEngine/ImportStage+Completion.swift:10` | Hoàn tất nhập (không dùng cho nguồn liên tục) |
| `SourceStatusReason` (`unavailable`, `signInRequired`, `diskFull`) | `Sources/PhotoVaultEngine/ImportHolds.swift:5` | Lý do giữ nguồn |
| `readResource` và kiểm tra hash | `Sources/PhotoVaultEngine/ExportWorker+SourceFailures.swift:8`, `:25` | Xuất file |
| `uploadsAllowedNow` | `Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift:71` | Nền của `TransferGate` (R10) |
| Migration | `Sources/PhotoVaultStore/Schema.swift:7`–`11` (mới nhất `v5-sources`); `Sources/PhotoVaultStore/Schema+Sources.swift:5` | Thêm migration (R11) |
| `RemoteIdIndex` (actor, ánh xạ đường dẫn ↔ id) | `Sources/PhotoVaultDrive/RemoteIdIndex.swift:7` | Chuyển vào cột của `import_item` |
| Adapter Dropbox nhập một lần | `Sources/PhotoVaultDropbox/DropboxImportSource.swift:8` (`probe` `:30`, `listFiles` `:34`, `inspect` `:41`, `exportResource` `:52`) | Điểm xuất phát của adapter liên tục |
| Liệt kê Dropbox (`list_folder`, `continue`) | `Sources/PhotoVaultDropbox/DropboxClient.swift:59`, `:65`, `:72` | Đường feed |
| `DropboxListEntry` | `Sources/PhotoVaultDropbox/DropboxModels.swift:3` | Ánh xạ mục feed |
| `ChangeTracker` (chỉ Photos) | `Sources/PhotoVaultEngine/ChangeTracker.swift:26` | Mẫu transaction theo thay đổi |
| `FakeContentSource` | `Sources/PhotoVaultTestSupport/FakeContentSource.swift:5` | Fake cho test |

## Hướng dẫn thêm nhà cung cấp

Tài liệu này là hướng dẫn duy nhất cho nhà cung cấp nguồn liên tục. Thêm một nhà cung cấp là: viết adapter, khai báo kind, đăng ký, rồi qua đủ các mục dưới đây.

| Mục | Việc phải làm |
|---|---|
| Hợp đồng | Triển khai `ContinuousSource` (mục trên). Nhận `SourceConfig` gồm `remoteRootId` (nil nếu là toàn bộ tài khoản). |
| Lỗi | Chỉ ném `SourceError`: `unavailable` (không kết nối, thư mục vắng), `rootChanged` (gốc đổi hoặc bị xoá, R1–R2), `fileMissing`, `fileChanged`, `accessRevoked` (cần đăng nhập lại), `busy` (giới hạn tốc độ, 5xx), `readFailed(code:)`. Không ném lỗi khác: `readResource` coi lỗi lạ là `unavailable`. Lỗi không chứa đường dẫn hay tên file (FR-123). |
| Cursor và `isComplete` | Cursor là chuỗi mờ. Cursor không còn hợp lệ được xử lý trong adapter bằng listing đầy đủ với `isComplete = true`. Chỉ listing đầy đủ mới được xoá theo "không có trong danh sách" (và chịu R3). |
| Thứ tự và gộp | Trả về trạng thái ròng theo từng đường dẫn, theo thứ tự feed (R14). |
| Hash | `contentHash` chỉ là tín hiệu thay đổi. `inspect` trả về hash của byte đã đọc (R6). Không dùng ETag multipart như MD5. |
| Gốc | Lưu id gốc khi thêm nguồn; kiểm tra trước `probe()` và trước mỗi listing đầy đủ (R1). |
| Xác thực | OAuth PKCE hoặc khoá, chỉ quyền đọc. Grant lưu trong Keychain dưới `CloudTokenAccount.importGrant(id)` (`import-<sourceId>`), mỗi nguồn một bản (`SourceModels.swift:54`). |
| Đăng ký | Thêm case vào `SourceKind` (`SourceModels.swift:41`), `SourceRegistry.add` (`SourceRegistry.swift:12`), và stage đọc riêng cho nguồn liên tục (`ImportStage.swift:25` hiện chỉ lấy `kind.isImport`). |
| Kiểm thử | Fake feed có các kịch bản R1–R15 (đổi tên và tạo lại gốc, xoá gốc, reset, hơn 500 hành động, `IMG (2).jpg` có sẵn, byte đổi giữa feed và đọc, cặp đến ở hai lần kiểm tra, nhà cung cấp lỗi, mạng tốn kém). Log không có đường dẫn, tên, id hay email. |

Bảng nhà cung cấp ở trên là phác thảo; mỗi nhà cung cấp phải được kiểm chứng trước khi viết code.

## Cách tiếp tục

1. Đọc kế hoạch `plans/261110-0805-17-dropbox-continuous/plan.md` và bản audit `reports/plan-audit-dropbox-continuous.md` trên nhánh `feat/17-dropbox-continuous` (worktree `photovault-17-dropbox-continuous`). Plan đã có quyết định của lead cho C1, C2, I1–I8.
2. Gộp các mục Minor của audit (M1 gấp chữ hoa thường trong Swift, M5 thứ tự delta, M6 `ready`, M10 `markRemoved` theo từng asset, M11 `.item` chỉ một test) vào phase 01–04 trước khi viết code.
3. Chạy spike hoặc owner E2E cho cấu trúc thật của Dropbox khi đổi tên thư mục gốc (xem câu hỏi mở).
4. Với nhà cung cấp mới: viết một tài liệu adapter ngắn, kiểm tra R1–R15, rồi thêm kind và adapter theo mẫu của `DropboxImportSource`.

## Câu hỏi mở

- Khi đổi tên thư mục Dropbox đang theo dõi, Dropbox trả `reset`, `path/not_found` hay một mục `deleted` cho gốc? Có mục `deleted` cho từng con của thư mục đã xoá không? Owner E2E (đổi tên thư mục đang theo dõi) sẽ trả lời.
- Owner có muốn ngưỡng hỏi trước khi một lần kiểm tra có quá nhiều file đổi (đề xuất: hơn 50 file) không? Đây là lựa chọn (b) của audit I6, chưa được chọn.
- Xoá một ảnh trong Photos có đưa lại dòng `duplicate` của nguồn liên tục vào hàng đợi không (hook ở `ChangeTracker`)? Hiện là giới hạn đã ghi nhận.
- Dropbox Camera Uploads có giữ nguyên byte HEIC so với bản gốc trong Photos không (dedupe bằng SHA-256)?
- Với `drive.file`, thư mục do tài khoản khác tạo có cho app đọc file mới được không?
- Chu kỳ 15 phút đủ nhanh cho owner hay cần longpoll?
