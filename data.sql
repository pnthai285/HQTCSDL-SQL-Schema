/*******************************************************************************
 * FILE 2: DATA SEEDING (DML)
 * Description: Tạo dữ liệu mẫu phục vụ kiểm thử các kịch bản tranh chấp đồng thời.
 * Note: Dữ liệu được phân chia cụ thể theo từng cặp Procedure trong file procedure.txt
 *******************************************************************************/

USE DB_TranhChapDongThoi;
GO

-- =============================================================================
-- PHẦN 0: LÀM SẠCH DỮ LIỆU CŨ (CLEANUP)
-- Xóa bảng con trước, bảng cha sau để không bị lỗi Khóa ngoại (FK)
-- =============================================================================
PRINT '--- BAT DAU LAM SACH DU LIEU CU ---';

-- 1. Xóa các bảng chi tiết / liên kết nhiều-nhiều
DELETE FROM SANPHAM_KHUYENMAI;
DELETE FROM CHITIET_DONHANG;
DELETE FROM CHITIET_DONDATHANG_NSX;
DELETE FROM CHITIET_PHIEUNHAPKHO;

-- 2. Xóa các bảng giao dịch (Transaction tables)
-- Lưu ý: Xóa DONHANG trước vì nó tham chiếu đến PHIEUGIAMGIA
DELETE FROM DONHANG; 
DELETE FROM DONDATHANG_NSX;
DELETE FROM PHIEUNHAPKHO;
DELETE FROM PHIEUGIAMGIA;

-- 3. Xóa các bảng thông tin mở rộng của đối tượng
DELETE FROM THETHANHVIEN;

-- 4. Xóa các bảng danh mục chính (Master tables)
-- Lưu ý thứ tự xóa
DELETE FROM SANPHAM;    -- Tham chiếu NSX, DanhMuc
DELETE FROM KHACHHANG;
DELETE FROM NHANVIEN;
DELETE FROM KHUYENMAI;
DELETE FROM NHASANXUAT;
DELETE FROM DANHMUC;

PRINT '--- DA XOA DU LIEU CU THANH CONG ---';
GO

-- =============================================================================
-- DỮ LIỆU NỀN (MASTER DATA)
-- Cần thiết để thỏa mãn khóa ngoại cho các bảng nghiệp vụ bên dưới
-- =============================================================================
INSERT INTO DANHMUC (MaDanhMuc, TenDanhMuc, MoTa) 
VALUES ('DM001', N'Điện tử', N'Đồ điện tử gia dụng');

INSERT INTO NHASANXUAT (MaNSX, TenNSX, DiaChi, SoDienThoai) 
VALUES ('NSX001', N'Samsung', N'Hàn Quốc', '0909000111');

INSERT INTO NHANVIEN (MaNhanVien, HoTen, ChucVu) 
VALUES ('NV001', N'Nguyễn Văn Quản Lý', N'Quan Ly');

INSERT INTO KHUYENMAI (MaKhuyenMai, TenKhuyenMai, TiLeKhuyenMai, NgayBatDau, NgayKetThuc, SoLuongToiDa)
VALUES ('KM001', N'Sale Tet', 0.2, '2025-01-01', '2025-02-01', 1000);


-- =============================================================================
-- KỊCH BẢN 1: DEADLOCK (Conversion Deadlock)
-- KỊCH BẢN 2: UNREPEATABLE READ
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_TaoPhieuGiamGiaSinhNhat (T1)
--    2. sp_CapNhatHangTheThanhVien (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Cần 1 Khách hàng (KH_A) có sinh nhật là THÁNG HIỆN TẠI (để T1 quét thấy).
--    - Khách hàng này đang ở hạng 'Bac'.
--    - Có tích lũy gần đủ để lên hạng 'Vang' (để T2 thực hiện cập nhật).
-- =============================================================================

-- 1. Tạo Khách hàng A (Sinh nhật luôn là tháng hiện tại của hệ thống)
INSERT INTO KHACHHANG (MaKhachHang, HoTen, SoDienThoai, NgaySinh, DiaChi)
VALUES ('KH_A', N'Nguyễn Văn A', '0912345678', DATEFROMPARTS(1990, MONTH(GETDATE()), 15), N'Hà Nội');

-- 2. Tạo Thẻ thành viên hạng Bạc cho KH_A
-- Tích lũy 9.9tr (Giả sử quy định 10tr lên Vàng -> T2 sẽ update bảng này)
INSERT INTO THETHANHVIEN (MaThe, HangThe, TongTienTichLuy, NgayBatDauHieuLuc, MaKhachHang)
VALUES ('CARD_A', N'Bac', 9900000, '2023-01-01', 'KH_A');

-- 3. Tạo Đơn hàng mới (Để T2 đọc được và tính tổng tiền mua sắm -> kích hoạt logic thăng hạng)
INSERT INTO DONHANG (MaDonHang, NgayLap, ThanhTien, MaKhachHang, MaNhanVien)
VALUES ('DH_A_New', GETDATE(), 200000, 'KH_A', 'NV001');


-- =============================================================================
-- KỊCH BẢN 3: PHANTOM READ
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_TaoPhieuGiamGiaSinhNhat (T1)
--    2. sp_CapNhatThongTinThanhVien (T3)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Giả sử T1 đang quét danh sách khách hàng sinh nhật THÁNG 5.
--    - Cần tạo KH01, KH02 có sinh nhật Tháng 5 (Dữ liệu T1 thấy ban đầu).
--    - Cần tạo KH03 có sinh nhật Tháng 4 (Dữ liệu T1 không thấy, nhưng T3 sẽ sửa thành Tháng 5).
-- =============================================================================

-- 1. KH thuộc phạm vi quét của T1 (Tháng 5)
INSERT INTO KHACHHANG (MaKhachHang, HoTen, SoDienThoai, NgaySinh, DiaChi)
VALUES 
('KH01', N'Trần Thị B', '0912345679', '1995-05-01', N'HCM'),
('KH02', N'Lê Văn C', '0912345680', '1998-05-20', N'Đà Nẵng');

-- 2. KH nằm ngoài phạm vi quét (Tháng 4) -> Là đối tượng gây ra "Bóng ma" khi bị update
INSERT INTO KHACHHANG (MaKhachHang, HoTen, SoDienThoai, NgaySinh, DiaChi)
VALUES ('KH03', N'Phạm Văn D', '0912345681', '1992-04-15', N'Cần Thơ');


-- =============================================================================
-- KỊCH BẢN 4: LOST UPDATE (Trên cùng một Sản Phẩm)
-- KỊCH BẢN 5: DEADLOCK (Do giữ S-Lock khi đọc)
-- KỊCH BẢN 6: DIRTY READ (Đọc dữ liệu chưa commit)
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_Update_SanPham (T1) vs sp_Update_SanPham (T2) (Lost Update/Deadlock)
--    2. sp_Delete_SanPham (T1) vs sp_Update_SanPham (T2) (Dirty Read)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Cần một sản phẩm cụ thể (SP001) để 2 giao tác cùng trỏ vào thao tác.
-- =============================================================================

-- 1. Tạo sản phẩm SP001
INSERT INTO SANPHAM (MaSanPham, TenSanPham, MoTa, GiaNiemYet, TonKho, TonKhoToiDa, MaNSX, MaDanhMuc)
VALUES ('SP001', N'Smart TV 4K', N'TV thông minh', 15000000, 50, 100, 'NSX001', 'DM001');

-- 2. Tạo dữ liệu liên kết (để test Foreign Key check trong quá trình Update/Delete)
INSERT INTO SANPHAM_KHUYENMAI (MaSanPham, MaKhuyenMai) VALUES ('SP001', 'KM001');


-- =============================================================================
-- KỊCH BẢN 7: LOST UPDATE (Tồn kho)
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_ThemChiTietDonHang (T1)
--    2. sp_ThemChiTietDonHang (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Cần 1 Sản phẩm (SP_LU) có Tồn kho xác định (100).
--    - Cần 1 Đơn hàng (DH_LU) đã có sẵn header để 2 giao tác cùng insert chi tiết vào.
--    - Tình huống: T1 đọc tồn 100, T2 đọc tồn 100 -> Cả 2 cùng trừ và ghi đè sai lệch.
-- =============================================================================

-- 1. Sản phẩm test Lost Update
INSERT INTO SANPHAM (MaSanPham, TenSanPham, MoTa, GiaNiemYet, TonKho, TonKhoToiDa, MaNSX, MaDanhMuc)
VALUES ('SP_LU', N'Nồi Cơm Điện', N'Nấu cơm ngon', 2000000, 100, 200, 'NSX001', 'DM001');

-- 2. Đơn hàng rỗng (Chưa có chi tiết)
INSERT INTO DONHANG (MaDonHang, NgayLap, ThanhTien, MaKhachHang, MaNhanVien)
VALUES ('DH_LU', GETDATE(), 0, 'KH_A', 'NV001');


-- =============================================================================
-- KỊCH BẢN 8: DUPLICATE KEY / INSERT CONFLICT
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_TaoDonHang (T1)
--    2. sp_TaoDonHang (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Kịch bản này chủ yếu dựa vào tham số đầu vào (cùng mã đơn hàng).
--    - Dữ liệu cần thiết chỉ là sự tồn tại của Khách hàng (KH_A đã tạo ở trên).
--    - (Không cần insert thêm data đặc thù ở bước này).
-- =============================================================================


-- =============================================================================
-- KỊCH BẢN 9: DEADLOCK (Cập nhật chéo Đơn hàng & Phiếu giảm giá)
-- -----------------------------------------------------------------------------
-- Cặp Procedure: 
--    1. sp_ApDungPhieuGiamGia (T1)
--    2. sp_ApDungPhieuGiamGia (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - Cần 1 Phiếu giảm giá (VOUCHER_X) trạng thái 'ChuaSuDung'.
--    - Cần 1 Đơn hàng (DH_DL_01) chưa áp dụng mã.
--    - Tình huống: Cả 2 cùng đọc bảng DONHANG (S-Lock), sau đó đều muốn Update (X-Lock).
-- =============================================================================

-- 1. Phiếu giảm giá hợp lệ
INSERT INTO PHIEUGIAMGIA (MaPhieu, TiLeGiamGia, NgayPhatHanh, NgayHetHan, TrangThai, MaKhachHang)
VALUES ('VOUCHER_X', 0.1, '2023-01-01', '2025-12-31', N'ChuaSuDung', 'KH_A');

-- 2. Đơn hàng chưa thanh toán, chưa có mã giảm giá (MaPhieuGiamGia = NULL)
INSERT INTO DONHANG (MaDonHang, NgayLap, LoaiDonHang, ThanhTien, MaKhachHang, MaNhanVien, MaPhieuGiamGia)
VALUES ('DH_DL_01', GETDATE(), N'MuaTrucTiep', 5000000, 'KH_A', 'NV001', NULL);


-- ===================================================================
-- ===================================================================
-- APPEND Ở ĐÂY


PRINT '=== HOÀN TẤT TẠO DỮ LIỆU MẪU CHO CÁC KỊCH BẢN TRANH CHẤP ==='
GO