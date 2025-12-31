USE DB_TranhChapDongThoi;
GO

--Thêm chi tiết đơn hàng (LOST UPDATE)
CREATE OR ALTER PROCEDURE sp_ThemChiTietDonHang
    @MaDH VARCHAR(20),
    @MaSP VARCHAR(20),
    @SoLuong INT
AS
BEGIN
	-- Cô lập giao tác : Đảm bảo chỉ đọc được những dữ liệu đã commit
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Kiểm tra MaSP và MaDH có tồn tại hay không
        IF NOT EXISTS (SELECT 1 FROM SANPHAM WHERE MaSanPham = @MaSP) OR 
           NOT EXISTS (SELECT 1 FROM DONHANG WHERE MaDonHang = @MaDH)
        BEGIN
            ROLLBACK TRANSACTION;
            PRINT N'Lỗi: Mã SP hoặc Mã DH không tồn tại';
            RETURN;
        END

        -- Sử dụng UPDLOCK để chặn các giao tác khác đọc dữ liệu tồn kho cũ 
        DECLARE @TonKhoHT INT;
        SELECT @TonKhoHT = TonKho 
        FROM SANPHAM WITH (UPDLOCK) 
        WHERE MaSanPham = @MaSP;

        -- Kiểm tra tồn kho
        IF @TonKhoHT >= @SoLuong
        BEGIN
            -- Giả lập độ trễ để kiểm chứng việc chặn giao tác thứ 2
            WAITFOR DELAY '00:00:10'; 

            -- Lấy giá hiện tại và thêm mới chi tiết đơn hàng 
            INSERT INTO CHITIET_DONHANG (MaDonHang, MaSanPham, SoLuong, DonGia)
            SELECT @MaDH, @MaSP, @SoLuong, GiaNiemYet FROM SANPHAM WHERE MaSanPham = @MaSP;

            -- Giảm số lượng tồn kho tương ứng
            UPDATE SANPHAM SET TonKho = TonKho - @SoLuong WHERE MaSanPham = @MaSP;

            -- Tính lại tổng giá trị tạm tính của Đơn hàng
            UPDATE DONHANG 
            SET ThanhTien = (SELECT SUM(SoLuong * DonGia) FROM CHITIET_DONHANG WHERE MaDonHang = @MaDH)
            WHERE MaDonHang = @MaDH;

            COMMIT TRANSACTION;
            PRINT N'Thành công: Đã thêm chi tiết và cập nhật kho';
        END
        ELSE
        BEGIN
            ROLLBACK TRANSACTION;
            PRINT N'Lỗi: Tồn kho không đủ';
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT ERROR_MESSAGE();
    END CATCH
END;
GO

-- Tạo đơn hàng (PHANTOM READ)
CREATE OR ALTER PROCEDURE sp_TaoDonHang
    @MaDH VARCHAR(20),
    @MaKH VARCHAR(20),
    @NgayDat DATETIME,
    @HinhThuc NVARCHAR(50),
    @TrangThai NVARCHAR(50)
AS
BEGIN
    --Serializable : Khóa phạm vi ngăn chặn bất cứ ai chèn thêm hoặc sửa đổi dữ liệu trong vùng mà giao tác đang làm việc
	-- => Sử dụng SERIALIZABLE để tránh lỗi đọc bóng ma khi kiểm tra trùng mã
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Kiểm tra MaKH có tồn tại hay không
        IF NOT EXISTS (SELECT 1 FROM KHACHHANG WHERE MaKhachHang = @MaKH)
        BEGIN
            ROLLBACK TRANSACTION;
            PRINT N'Lỗi: Khách hàng không tồn tại';
            RETURN;
        END

        -- 2. Kiểm tra trùng lặp MaDH
        IF EXISTS (SELECT 1 FROM DONHANG WITH (UPDLOCK) WHERE MaDonHang = @MaDH)
        BEGIN
            PRINT N'Lỗi: Mã đơn hàng đã tồn tại';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- Giả lập độ trễ để test T2
        WAITFOR DELAY '00:00:10';

        -- 3. Thêm mới dữ liệu vào bảng DONHAN
        INSERT INTO DONHANG (MaDonHang, NgayLap, LoaiDonHang, ThanhTien, MaKhachHang, MaNhanVien)
        VALUES (@MaDH, @NgayDat, @HinhThuc, 0, @MaKH, 'NV010');

        COMMIT TRANSACTION;
        PRINT N'Thành công: Đã tạo đơn hàng';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT ERROR_MESSAGE();
    END CATCH
END;
GO


--Áp dụng phiếu giảm giá (DEADLOCK)
CREATE OR ALTER PROCEDURE sp_ApDungPhieuGiamGia
    @MaDH VARCHAR(20),
    @MaKH VARCHAR(20)
AS
BEGIN
	-- Cô lập giao tác : Đảm bảo chỉ đọc được những dữ liệu đã commit
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Kiểm tra MaDH và dùng UPDLOCK để ngăn chặn Deadlock nâng cấp khóa
        IF NOT EXISTS (SELECT 1 FROM DONHANG WITH (UPDLOCK) WHERE MaDonHang = @MaDH)
        BEGIN
            ROLLBACK TRANSACTION;
            PRINT N'Lỗi: Đơn hàng không tồn tại';
            RETURN;
        END

        -- Tìm phiếu giảm giá hợp lệ và chưa sử dụng
        DECLARE @MaPhieu VARCHAR(20), @TiLe FLOAT;
        SELECT TOP 1 @MaPhieu = MaPhieu, @TiLe = TiLeGiamGia 
        FROM PHIEUGIAMGIA 
        WHERE MaKhachHang = @MaKH AND TrangThai = N'ChuaSuDung'
        ORDER BY TiLeGiamGia DESC;

        IF @MaPhieu IS NOT NULL
        BEGIN
            WAITFOR DELAY '00:00:10';

            -- Cập nhật lại TongTien mới sau khi giảm giá
            UPDATE DONHANG 
            SET ThanhTien = ThanhTien * (1 - @TiLe),
                MaPhieuGiamGia = @MaPhieu
            WHERE MaDonHang = @MaDH;

            -- Đánh dấu phiếu giảm giá đã được sử dụng
            UPDATE PHIEUGIAMGIA SET TrangThai = N'DaSuDung' WHERE MaPhieu = @MaPhieu;

            COMMIT TRANSACTION;
            PRINT N'Thành công: Đã áp dụng mã giảm giá';
        END
        ELSE
        BEGIN
            -- Nếu không tìm thấy, trả về tổng tiền cũ
            PRINT N'Thông báo: Không tìm thấy phiếu giảm giá hợp lệ';
            COMMIT TRANSACTION;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        -- Nếu hệ thống buộc phải Kill giao tác do Deadlock, thông báo sẽ hiển thị ở đây
        PRINT ERROR_MESSAGE();
    END CATCH
END;
GO