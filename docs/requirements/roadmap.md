# Lộ trình

- **Cập nhật:** 2026-11-11
- **Nguồn:** [spec §15](./photovault-spec-v1.md), [CHANGELOG](../../CHANGELOG.md), issue #17

Lộ trình này không có ngày. Mục "Tương lai xa" chưa được lên lịch; thứ tự là ưu tiên của owner, không phải cam kết.

## Đã làm

| Phiên bản | Ngày | Nội dung chính |
|---|---|---|
| 0.1.0 | 2026-11-09 | Ứng dụng menu bar sao lưu Photos sang Google Drive và thư mục local/NAS |
| 0.2.0 | 2026-11-09 | Nhiều nguồn; nhập một lần từ thư mục trên Mac (#22); một thư mục cho mỗi ngày; khởi động lại từ onboarding (factory reset); giao diện tiếng Việt và tiếng Anh |
| 0.3.0 | 2026-11-10 | Nhập một lần từ thư mục Google Drive (Picker, `drive.file`) và từ thư mục Dropbox (#25) |
| 0.4.0 | 2026-11-10 | By lens, tách ngày theo nơi chụp, nhập Drive đọc được nội dung thư mục (xem bảng dưới) |
| 0.5.0 | 2026-11-10 | Nhập từ thư mục Google Drive/Dropbox đồng bộ trên máy (không còn cảnh báo "chưa xác minh"); dòng trạng thái hiện file đang chuyển; hàng đợi nhập dạng danh sách; Huỷ nhập có hiệu lực ngay; đường dẫn đầy đủ trong lịch sử nhập |
| 0.5.1 | 2026-11-10 | Chỉ bảo trì: test không còn phụ thuộc tốc độ máy hay thời gian chờ ngẫu nhiên, CI ổn định trên máy macOS của GitHub; thêm test cho phần huỷ nhập |
| 0.6.0 | 2026-11-11 | Nhập từ cloud nhanh hơn: tải đợt sau trong lúc upload đợt trước (#69); Tạm dừng dừng cả việc tải về staging |

### 0.4.0 (phát hành 2026-11-10)

| Việc | Trạng thái |
|---|---|
| Xem By lens: nhóm ảnh theo ống kính trên Drive (issue #24, PR #30, FR-107, quyết định [0027](../decisions/0027-by-lens-view.md)) | Đã phát hành |
| Tách một ngày thành nhiều thư mục khi ảnh chụp ở nhiều nơi (issue #27, PR #35, quyết định [0028](../decisions/0028-split-day-by-place.md)) | Đã phát hành |
| Nhập từ thư mục Google Drive đọc được nội dung thư mục đã chọn (PR #34, quyết định [0030](../decisions/0030-drive-import-reads-folder-contents.md), `drive.readonly`) | Đã phát hành; chờ owner kiểm tra trên tài khoản thật |
| Phân loại chính xác ảnh đã lưu từ app khác, "Saved from <app>" (issue #31, nghiên cứu ở PR #37) | Đóng: không có tín hiệu chắc chắn để biết app nguồn; giữ nguyên FR-20 (ảnh chat vào `saved`, video vào `camera`) |

## Tương lai xa

Chỉ Photos là nguồn liên tục ([quyết định 0029](../decisions/0029-photos-only-continuous-source.md)). Cơ chế thêm nguồn và các quy tắc an toàn: [continuous-source-extension](../architecture/continuous-source-extension.md).

| Thứ tự | Nội dung | Trạng thái |
|---|---|---|
| 1 | Nguồn liên tục Dropbox (issue #17) | Chưa lên lịch. Issue tạm dừng; kế hoạch và bản audit trên `feat/17-dropbox-continuous` |
| 2 | Nguồn liên tục OneDrive | Chưa lên lịch |
| 3 | Nguồn liên tục Drive của tài khoản Google khác | Chưa lên lịch. Cần kiểm tra trên tài khoản thật rằng `drive.readonly` liệt kê được thư mục lồng nhau (quyết định 0030) |
| 4 | Nguồn liên tục S3-compatible | Chưa lên lịch. Cần bộ chặn xoá hàng loạt |
| 5 | Nguồn liên tục Flickr | Chưa lên lịch. Cần API key và secret từ owner |

Việc tiếp theo đã có issue: cửa sổ Lịch sử, xem lại file đã đồng bộ từ Photos, từng lần backfill và từng lần nhập (#82, cho 0.7.0).

Các mục khác trong spec §15, chưa lên lịch:

- S3-compatible với layout ổn định `YYYY/MM`, multipart và tiếp tục khi lỗi, key không có quyền xoá, Object Lock.
- OneDrive, WebDAV, Immich.
- Google Takeout và Photos Picker cho tài khoản Google khác.
- Mã hoá phía client.
- View `Albums`.
- Layout gom sự kiện và chuyến đi.
- Công cụ khôi phục về Photos.
- Rule chọn lọc nâng cao.
- Di chuyển file khi owner sửa ngày.
- Heartbeat và thông báo Telegram.
- Gợi ý giải phóng iCloud.
- View cho NAS.
