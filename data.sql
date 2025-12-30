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
DELETE FROM SANPHAM;
-- Tham chiếu NSX, DanhMuc
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
INSERT INTO
    DANHMUC (MaDanhMuc, TenDanhMuc, MoTa)
VALUES (
        'DM001',
        N'Điện tử',
        N'Đồ điện tử gia dụng'
    );

INSERT INTO
    NHASANXUAT (
        MaNSX,
        TenNSX,
        DiaChi,
        SoDienThoai
    )
VALUES (
        'NSX001',
        N'Samsung',
        N'Hàn Quốc',
        '0909000111'
    );

INSERT INTO
    NHANVIEN (MaNhanVien, HoTen, ChucVu)
VALUES (
        'NV001',
        N'Nguyễn Văn Quản Lý',
        N'Quan Ly'
    );

INSERT INTO
    KHUYENMAI (
        MaKhuyenMai,
        TenKhuyenMai,
        TiLeKhuyenMai,
        NgayBatDau,
        NgayKetThuc,
        SoLuongToiDa
    )
VALUES (
        'KM001',
        N'Sale Tet',
        0.2,
        '2025-01-01',
        '2025-02-01',
        1000
    );

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
INSERT INTO
    KHACHHANG (
        MaKhachHang,
        HoTen,
        SoDienThoai,
        NgaySinh,
        DiaChi
    )
VALUES (
        'KH_A',
        N'Nguyễn Văn A',
        '0912345678',
        DATEFROMPARTS (1990, MONTH(GETDATE ()), 15),
        N'Hà Nội'
    );

-- 2. Tạo Thẻ thành viên hạng Bạc cho KH_A
-- Tích lũy 9.9tr (Giả sử quy định 10tr lên Vàng -> T2 sẽ update bảng này)
INSERT INTO
    THETHANHVIEN (
        MaThe,
        HangThe,
        TongTienTichLuy,
        NgayBatDauHieuLuc,
        MaKhachHang
    )
VALUES (
        'CARD_A',
        N'Bac',
        9900000,
        '2023-01-01',
        'KH_A'
    );

-- 3. Tạo Đơn hàng mới (Để T2 đọc được và tính tổng tiền mua sắm -> kích hoạt logic thăng hạng)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        ThanhTien,
        MaKhachHang,
        MaNhanVien
    )
VALUES (
        'DH_A_New',
        GETDATE (),
        200000,
        'KH_A',
        'NV001'
    );

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
INSERT INTO
    KHACHHANG (
        MaKhachHang,
        HoTen,
        SoDienThoai,
        NgaySinh,
        DiaChi
    )
VALUES (
        'KH01',
        N'Trần Thị B',
        '0912345679',
        '1995-05-01',
        N'HCM'
    ),
    (
        'KH02',
        N'Lê Văn C',
        '0912345680',
        '1998-05-20',
        N'Đà Nẵng'
    );

-- 2. KH nằm ngoài phạm vi quét (Tháng 4) -> Là đối tượng gây ra "Bóng ma" khi bị update
INSERT INTO
    KHACHHANG (
        MaKhachHang,
        HoTen,
        SoDienThoai,
        NgaySinh,
        DiaChi
    )
VALUES (
        'KH03',
        N'Phạm Văn D',
        '0912345681',
        '1992-04-15',
        N'Cần Thơ'
    );

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
INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP001',
        N'Smart TV 4K',
        N'TV thông minh',
        15000000,
        50,
        100,
        'NSX001',
        'DM001'
    );

-- 2. Tạo dữ liệu liên kết (để test Foreign Key check trong quá trình Update/Delete)
INSERT INTO
    SANPHAM_KHUYENMAI (MaSanPham, MaKhuyenMai)
VALUES ('SP001', 'KM001');

-- =============================================================================
INSERT INTO DANHMUC(MaDanhMuc, TenDanhMuc) VALUES ('DM01', N'Test');
INSERT INTO NHASANXUAT(MaNSX, TenNSX) VALUES ('NSX01', N'Test Factory');
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
INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP_LU',
        N'Nồi Cơm Điện',
        N'Nấu cơm ngon',
        2000000,
        100,
        200,
        'NSX001',
        'DM001'
    );

-- 2. Đơn hàng rỗng (Chưa có chi tiết)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        ThanhTien,
        MaKhachHang,
        MaNhanVien
    )
VALUES (
        'DH_LU',
        GETDATE (),
        0,
        'KH_A',
        'NV001'
    );

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
INSERT INTO
    PHIEUGIAMGIA (
        MaPhieu,
        TiLeGiamGia,
        NgayPhatHanh,
        NgayHetHan,
        TrangThai,
        MaKhachHang
    )
VALUES (
        'VOUCHER_X',
        0.1,
        '2023-01-01',
        '2025-12-31',
        N'ChuaSuDung',
        'KH_A'
    );

-- 2. Đơn hàng chưa thanh toán, chưa có mã giảm giá (MaPhieuGiamGia = NULL)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_DL_01',
        GETDATE (),
        N'MuaTrucTiep',
        5000000,
        'KH_A',
        'NV001',
        NULL
    );

-- ===================================================================
-- ===================================================================
-- ==========================TUAN=====================================
-- KỊCH BẢN CHO 3 PROCEDURES THEO DESCRIPTION.MD (procedures-tuan.sql)
-- Các kịch bản tranh chấp: Lost Update, Phantom Read, Deadlock
-- ===================================================================

-- =============================================================================
-- KỊCH BẢN A: LOST UPDATE
-- Cặp Procedure: sp_XuLyDonHangThanhVien (T1) & sp_XuLyDonHangVangLai (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - T1 và T2 cùng đọc SoLuongToiDa của FlashSale = 10, cả 2 cùng trừ
--    - và ghi đè -> Mất dữ liệu cập nhật của 1 giao dịch
-- =============================================================================

-- 1. Tạo thành viên cho kịch bản Lost Update
INSERT INTO
    KHACHHANG (
        MaKhachHang,
        HoTen,
        SoDienThoai,
        NgaySinh,
        DiaChi
    )
VALUES (
        'KH_LU_MEMBER',
        N'Nguyễn Thành Viên LU',
        '0911111111',
        '1990-06-15',
        N'Hà Nội'
    );

INSERT INTO
    THETHANHVIEN (
        MaThe,
        HangThe,
        TongTienTichLuy,
        NgayBatDauHieuLuc,
        MaKhachHang
    )
VALUES (
        'CARD_LU',
        N'Vang',
        15000000,
        '2024-01-01',
        'KH_LU_MEMBER'
    );

-- 2. Sản phẩm FlashSale với số lượng giới hạn = 10
INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP_FLASH_LU',
        N'iPhone 15 Pro FlashSale',
        N'Điện thoại cao cấp',
        25000000,
        50,
        100,
        'NSX001',
        'DM001'
    );

-- 3. FlashSale với SoLuongToiDa = 10 (chỉ có 10 suất khuyến mãi)
INSERT INTO
    KHUYENMAI (
        MaKhuyenMai,
        TenKhuyenMai,
        LoaiKhuyenMai,
        TiLeKhuyenMai,
        NgayBatDau,
        NgayKetThuc,
        SoLuongToiDa,
        CapDoTheApDung
    )
VALUES (
        'KM_FLASH_LU',
        N'Flash Sale iPhone',
        N'FlashSale',
        0.3,
        '2024-01-01',
        '2025-12-31',
        10,
        NULL
    );

INSERT INTO
    SANPHAM_KHUYENMAI (MaSanPham, MaKhuyenMai)
VALUES ('SP_FLASH_LU', 'KM_FLASH_LU');

-- 4. Đơn hàng T1 (Thành viên) - mua 2 sản phẩm
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_LU_T1',
        GETDATE (),
        N'ThanhVien',
        0,
        'KH_LU_MEMBER',
        'NV001',
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_LU_T1',
        'SP_FLASH_LU',
        2,
        0,
        NULL
    );

-- 5. Đơn hàng T2 (Vãng lai) - mua 7 sản phẩm (nhưng chỉ 3 được giảm giá)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_LU_T2',
        GETDATE (),
        N'VangLai',
        0,
        NULL,
        'NV001',
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_LU_T2',
        'SP_FLASH_LU',
        7,
        0,
        NULL
    );

-- =============================================================================
-- KỊCH BẢN B: PHANTOM READ
-- Cặp Procedure: sp_ThongKe_TongQuan_NgayHienTai (T1) & sp_XuLyDonHangVangLai (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - T1 đang thống kê doanh thu, T2 insert đơn hàng mới và commit
--    - T1 quét lại thấy "bóng ma" - đơn hàng mới xuất hiện giữa chừng
-- =============================================================================

-- 1. Đơn hàng đã có sẵn cho thống kê (đã có ThanhTien)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_PHANTOM_1',
        GETDATE (),
        N'ThanhVien',
        5000000,
        'KH_A',
        'NV001',
        NULL
    );

INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_PHANTOM_2',
        GETDATE (),
        N'ThanhVien',
        3000000,
        'KH_A',
        'NV001',
        NULL
    );

-- 2. Sản phẩm và đơn hàng "bóng ma" - sẽ được xử lý bởi T2 trong khi T1 đang chạy
INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP_PHANTOM',
        N'Tai nghe Bluetooth',
        N'Tai nghe không dây',
        1500000,
        100,
        200,
        'NSX001',
        'DM001'
    );

INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_PHANTOM_NEW',
        GETDATE (),
        N'VangLai',
        0,
        NULL,
        'NV001',
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_PHANTOM_NEW',
        'SP_PHANTOM',
        2,
        0,
        NULL
    );

-- =============================================================================
-- KỊCH BẢN C: DEADLOCK
-- Cặp Procedure: sp_XuLyDonHangThanhVien (T1) & sp_XuLyDonHangThanhVien (T2)
-- -----------------------------------------------------------------------------
-- Mô tả dữ liệu:
--    - T1 lock sản phẩm X, chờ Y. T2 lock sản phẩm Y, chờ X.
--    - => Circular dependency => Deadlock
-- =============================================================================

-- 1. Thêm thành viên thứ 2 cho kịch bản Deadlock
INSERT INTO
    KHACHHANG (
        MaKhachHang,
        HoTen,
        SoDienThoai,
        NgaySinh,
        DiaChi
    )
VALUES (
        'KH_DL_MEMBER2',
        N'Trần Thành Viên DL2',
        '0922222222',
        '1992-08-20',
        N'HCM'
    );

INSERT INTO
    THETHANHVIEN (
        MaThe,
        HangThe,
        TongTienTichLuy,
        NgayBatDauHieuLuc,
        MaKhachHang
    )
VALUES (
        'CARD_DL2',
        N'Vang',
        20000000,
        '2024-01-01',
        'KH_DL_MEMBER2'
    );

-- 2. Hai sản phẩm FlashSale
INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP_DL_X',
        N'MacBook Pro M3',
        N'Laptop cao cấp',
        50000000,
        20,
        50,
        'NSX001',
        'DM001'
    );

INSERT INTO
    SANPHAM (
        MaSanPham,
        TenSanPham,
        MoTa,
        GiaNiemYet,
        TonKho,
        TonKhoToiDa,
        MaNSX,
        MaDanhMuc
    )
VALUES (
        'SP_DL_Y',
        N'iPad Pro M2',
        N'Tablet cao cấp',
        30000000,
        30,
        50,
        'NSX001',
        'DM001'
    );

INSERT INTO
    KHUYENMAI (
        MaKhuyenMai,
        TenKhuyenMai,
        LoaiKhuyenMai,
        TiLeKhuyenMai,
        NgayBatDau,
        NgayKetThuc,
        SoLuongToiDa,
        CapDoTheApDung
    )
VALUES (
        'KM_DL_X',
        N'Flash Sale MacBook',
        N'FlashSale',
        0.15,
        '2024-01-01',
        '2025-12-31',
        10,
        NULL
    );

INSERT INTO
    KHUYENMAI (
        MaKhuyenMai,
        TenKhuyenMai,
        LoaiKhuyenMai,
        TiLeKhuyenMai,
        NgayBatDau,
        NgayKetThuc,
        SoLuongToiDa,
        CapDoTheApDung
    )
VALUES (
        'KM_DL_Y',
        N'Flash Sale iPad',
        N'FlashSale',
        0.20,
        '2024-01-01',
        '2025-12-31',
        10,
        NULL
    );

INSERT INTO
    SANPHAM_KHUYENMAI (MaSanPham, MaKhuyenMai)
VALUES ('SP_DL_X', 'KM_DL_X');

INSERT INTO
    SANPHAM_KHUYENMAI (MaSanPham, MaKhuyenMai)
VALUES ('SP_DL_Y', 'KM_DL_Y');

-- 3. Đơn hàng T1: Mua X trước, rồi Y (thứ tự trong CHITIET_DONHANG)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_DEADLOCK_T1',
        GETDATE (),
        N'ThanhVien',
        0,
        'KH_LU_MEMBER',
        'NV001',
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_DEADLOCK_T1',
        'SP_DL_X',
        1,
        0,
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_DEADLOCK_T1',
        'SP_DL_Y',
        1,
        0,
        NULL
    );

-- 4. Đơn hàng T2: Mua Y trước, rồi X (thứ tự ngược lại => gây deadlock)
INSERT INTO
    DONHANG (
        MaDonHang,
        NgayLap,
        LoaiDonHang,
        ThanhTien,
        MaKhachHang,
        MaNhanVien,
        MaPhieuGiamGia
    )
VALUES (
        'DH_DEADLOCK_T2',
        GETDATE (),
        N'ThanhVien',
        0,
        'KH_DL_MEMBER2',
        'NV001',
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_DEADLOCK_T2',
        'SP_DL_Y',
        1,
        0,
        NULL
    );

INSERT INTO
    CHITIET_DONHANG (
        MaDonHang,
        MaSanPham,
        SoLuong,
        DonGia,
        MaKhuyenMai
    )
VALUES (
        'DH_DEADLOCK_T2',
        'SP_DL_X',
        1,
        0,
        NULL
    );

--Append here

PRINT '=== HOÀN TẤT TẠO DỮ LIỆU MẪU CHO CÁC KỊCH BẢN TRANH CHẤP ==='