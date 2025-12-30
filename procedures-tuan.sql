USE DB_TranhChapDongThoi;
GO

/*******************************************************************************
* FILE: PROCEDURES-TUAN.SQL
* Description: Three stored procedures with conflict PREVENTION mechanisms
* Each procedure has @KichBan parameter to select which conflict fix to apply
* Author: Tuan
*******************************************************************************/

/*******************************************************************************
* PROCEDURE 1: sp_XuLyDonHangThanhVien
* Description: Process orders for registered members with tiered pricing
* KichBan 1: Fix LOST UPDATE (vs sp_XuLyDonHangVangLai)
* KichBan 2: Fix DEADLOCK (vs another sp_XuLyDonHangThanhVien)
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_XuLyDonHangThanhVien
    @MaDonHang VARCHAR(20),
    @MaKhachHang VARCHAR(20),
    @KichBan INT -- 1: Fix Lost Update, 2: Fix Deadlock
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @HangThe NVARCHAR(50);
    DECLARE @TamTinh DECIMAL(18,2) = 0;
    DECLARE @TongTien DECIMAL(18,2) = 0;
    DECLARE @MaSanPham VARCHAR(20);
    DECLARE @SoLuong INT;
    DECLARE @GiaBan DECIMAL(18,2);
    DECLARE @TiLeGiam FLOAT = 0;
    DECLARE @MaPhieuGiam VARCHAR(20) = NULL;
    DECLARE @MaKhuyenMai VARCHAR(20);
    DECLARE @GiaKhuyenMai DECIMAL(18,2);
    DECLARE @SoLuongKM INT;

    -- =========================================================================
    -- KỊCH BẢN 1: XỬ LÝ LOST UPDATE
    -- Vấn đề: T1 và T2 cùng đọc SoLuongToiDa = 10, cả 2 trừ và ghi đè -> mất update
    -- Giải pháp: Sử dụng WITH (UPDLOCK) khi đọc KHUYENMAI để giữ khóa cập nhật
    -- =========================================================================
    IF @KichBan = 1
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T1 [BAT DAU]: Xu ly don hang thanh vien (Fix Lost Update)';

            -- Get member's rank
            SELECT @HangThe = HangThe FROM THETHANHVIEN WHERE MaKhachHang = @MaKhachHang;

            -- Cursor through order items
            DECLARE cur_ChiTiet CURSOR FOR
                SELECT MaSanPham, SoLuong FROM CHITIET_DONHANG WHERE MaDonHang = @MaDonHang;

            OPEN cur_ChiTiet;
            FETCH NEXT FROM cur_ChiTiet INTO @MaSanPham, @SoLuong;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @MaKhuyenMai = NULL;
                SET @GiaKhuyenMai = NULL;

                -- [GIẢI PHÁP]: Dùng UPDLOCK để khóa dòng KHUYENMAI trước khi đọc
                -- T2 sẽ phải chờ nếu cố đọc cùng dòng này
                PRINT '>>> T1 [DOC VOI UPDLOCK]: Kiem tra FlashSale voi khoa cap nhat';
                SELECT TOP 1 
                    @MaKhuyenMai = km.MaKhuyenMai,
                    @GiaKhuyenMai = sp.GiaNiemYet * (1 - km.TiLeKhuyenMai),
                    @SoLuongKM = km.SoLuongToiDa
                FROM KHUYENMAI km WITH (UPDLOCK)
                INNER JOIN SANPHAM_KHUYENMAI spkm ON km.MaKhuyenMai = spkm.MaKhuyenMai
                INNER JOIN SANPHAM sp ON spkm.MaSanPham = sp.MaSanPham
                WHERE spkm.MaSanPham = @MaSanPham
                  AND km.LoaiKhuyenMai = N'FlashSale'
                  AND km.NgayBatDau <= GETDATE()
                  AND km.NgayKetThuc >= GETDATE()
                  AND km.SoLuongToiDa >= @SoLuong;

                IF @MaKhuyenMai IS NOT NULL
                BEGIN
                    SET @GiaBan = @GiaKhuyenMai;
                    
                    PRINT '>>> T1 [DANG CHO 10s]: Gia lap thoi gian xu ly...';
                    WAITFOR DELAY '00:00:10';
                    
                    -- Update FlashSale quantity - safe because we hold UPDLOCK
                    UPDATE KHUYENMAI 
                    SET SoLuongToiDa = SoLuongToiDa - @SoLuong 
                    WHERE MaKhuyenMai = @MaKhuyenMai;
                    PRINT '>>> T1 [DA CAP NHAT]: Tru so luong FlashSale an toan';
                END
                ELSE
                BEGIN
                    SELECT @GiaBan = GiaNiemYet FROM SANPHAM WHERE MaSanPham = @MaSanPham;
                END

                -- Update inventory
                UPDATE SANPHAM SET TonKho = TonKho - @SoLuong WHERE MaSanPham = @MaSanPham;
                UPDATE CHITIET_DONHANG SET DonGia = @GiaBan, MaKhuyenMai = @MaKhuyenMai
                WHERE MaDonHang = @MaDonHang AND MaSanPham = @MaSanPham;

                SET @TamTinh = @TamTinh + (@GiaBan * @SoLuong);
                FETCH NEXT FROM cur_ChiTiet INTO @MaSanPham, @SoLuong;
            END

            CLOSE cur_ChiTiet;
            DEALLOCATE cur_ChiTiet;

            SET @TongTien = @TamTinh;
            UPDATE DONHANG SET ThanhTien = @TongTien WHERE MaDonHang = @MaDonHang;

            COMMIT TRANSACTION;
            PRINT '>>> T1 [THANH CONG]: Khong bi Lost Update nho UPDLOCK';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF CURSOR_STATUS('local', 'cur_ChiTiet') >= 0
            BEGIN
                CLOSE cur_ChiTiet;
                DEALLOCATE cur_ChiTiet;
            END
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- =========================================================================
    -- KỊCH BẢN 2: XỬ LÝ DEADLOCK
    -- Vấn đề: T1 lock X, chờ Y. T2 lock Y, chờ X -> Circular wait -> Deadlock
    -- Giải pháp: Xử lý sản phẩm theo THỨ TỰ NHẤT QUÁN (ORDER BY MaSanPham)
    -- =========================================================================
    ELSE IF @KichBan = 2
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T1 [BAT DAU]: Xu ly don hang (Fix Deadlock - Thu tu nhat quan)';

            SELECT @HangThe = HangThe FROM THETHANHVIEN WHERE MaKhachHang = @MaKhachHang;

            -- [GIẢI PHÁP]: Xử lý theo ORDER BY MaSanPham để luôn lock cùng thứ tự
            DECLARE cur_ChiTiet_Ordered CURSOR FOR
                SELECT MaSanPham, SoLuong FROM CHITIET_DONHANG 
                WHERE MaDonHang = @MaDonHang
                ORDER BY MaSanPham; -- CRITICAL: Đảm bảo thứ tự nhất quán

            OPEN cur_ChiTiet_Ordered;
            FETCH NEXT FROM cur_ChiTiet_Ordered INTO @MaSanPham, @SoLuong;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @MaKhuyenMai = NULL;

                PRINT '>>> T1 [XU LY]: San pham ' + @MaSanPham + ' (theo thu tu ABC)';
                
                -- Lock the product with UPDLOCK
                SELECT TOP 1 
                    @MaKhuyenMai = km.MaKhuyenMai,
                    @GiaKhuyenMai = sp.GiaNiemYet * (1 - km.TiLeKhuyenMai)
                FROM KHUYENMAI km WITH (UPDLOCK)
                INNER JOIN SANPHAM_KHUYENMAI spkm ON km.MaKhuyenMai = spkm.MaKhuyenMai
                INNER JOIN SANPHAM sp WITH (UPDLOCK) ON spkm.MaSanPham = sp.MaSanPham
                WHERE spkm.MaSanPham = @MaSanPham
                  AND km.LoaiKhuyenMai = N'FlashSale'
                  AND km.SoLuongToiDa >= @SoLuong;

                IF @MaKhuyenMai IS NOT NULL
                BEGIN
                    SET @GiaBan = @GiaKhuyenMai;
                    UPDATE KHUYENMAI SET SoLuongToiDa = SoLuongToiDa - @SoLuong WHERE MaKhuyenMai = @MaKhuyenMai;
                END
                ELSE
                BEGIN
                    SELECT @GiaBan = GiaNiemYet FROM SANPHAM WHERE MaSanPham = @MaSanPham;
                END

                PRINT '>>> T1 [CHO 8s]: Gia lap xu ly...';
                WAITFOR DELAY '00:00:08';

                UPDATE SANPHAM SET TonKho = TonKho - @SoLuong WHERE MaSanPham = @MaSanPham;
                UPDATE CHITIET_DONHANG SET DonGia = @GiaBan WHERE MaDonHang = @MaDonHang AND MaSanPham = @MaSanPham;

                SET @TamTinh = @TamTinh + (@GiaBan * @SoLuong);
                FETCH NEXT FROM cur_ChiTiet_Ordered INTO @MaSanPham, @SoLuong;
            END

            CLOSE cur_ChiTiet_Ordered;
            DEALLOCATE cur_ChiTiet_Ordered;

            UPDATE DONHANG SET ThanhTien = @TamTinh WHERE MaDonHang = @MaDonHang;

            COMMIT TRANSACTION;
            PRINT '>>> T1 [THANH CONG]: Khong Deadlock nho thu tu nhat quan';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF CURSOR_STATUS('local', 'cur_ChiTiet_Ordered') >= 0
            BEGIN
                CLOSE cur_ChiTiet_Ordered;
                DEALLOCATE cur_ChiTiet_Ordered;
            END
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

/*******************************************************************************
* PROCEDURE 2: sp_XuLyDonHangVangLai
* Description: Process orders for guest customers with FlashSale capped at 3 units
* KichBan 1: Fix LOST UPDATE (vs sp_XuLyDonHangThanhVien)
* KichBan 2: Support PHANTOM READ fix (runs alongside sp_ThongKe)
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_XuLyDonHangVangLai
    @MaDonHang VARCHAR(20),
    @KichBan INT -- 1: Fix Lost Update, 2: Support Phantom Read test
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @TongTien DECIMAL(18,2) = 0;
    DECLARE @MaSanPham VARCHAR(20);
    DECLARE @SoLuongMua INT;
    DECLARE @GiaNiemYet DECIMAL(18,2);
    DECLARE @GiaSale DECIMAL(18,2);
    DECLARE @ThanhTien DECIMAL(18,2);
    DECLARE @SL_KM INT;
    DECLARE @SL_Goc INT;
    DECLARE @MaKhuyenMai VARCHAR(20);

    -- =========================================================================
    -- KỊCH BẢN 1: XỬ LÝ LOST UPDATE (Phối hợp với sp_XuLyDonHangThanhVien)
    -- Giải pháp: Sử dụng WITH (UPDLOCK) khi đọc KHUYENMAI
    -- =========================================================================
    IF @KichBan = 1
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T2 [BAT DAU]: Xu ly don hang vang lai (Fix Lost Update)';

            DECLARE cur_ChiTiet CURSOR FOR
                SELECT MaSanPham, SoLuong FROM CHITIET_DONHANG WHERE MaDonHang = @MaDonHang;

            OPEN cur_ChiTiet;
            FETCH NEXT FROM cur_ChiTiet INTO @MaSanPham, @SoLuongMua;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GiaNiemYet = GiaNiemYet FROM SANPHAM WHERE MaSanPham = @MaSanPham;

                -- [GIẢI PHÁP]: Dùng UPDLOCK - nếu T1 đang giữ, T2 phải chờ
                PRINT '>>> T2 [DOC VOI UPDLOCK]: Se bi TREO neu T1 dang giu khoa...';
                SET @MaKhuyenMai = NULL;
                SELECT TOP 1 
                    @MaKhuyenMai = km.MaKhuyenMai,
                    @GiaSale = @GiaNiemYet * (1 - km.TiLeKhuyenMai)
                FROM KHUYENMAI km WITH (UPDLOCK)
                INNER JOIN SANPHAM_KHUYENMAI spkm ON km.MaKhuyenMai = spkm.MaKhuyenMai
                WHERE spkm.MaSanPham = @MaSanPham
                  AND km.LoaiKhuyenMai = N'FlashSale'
                  AND km.SoLuongToiDa > 0;

                PRINT '>>> T2 [DA CO QUYEN]: (Dong nay chi hien khi T1 da xong hoac khong co T1)';

                IF @MaKhuyenMai IS NOT NULL
                BEGIN
                    SET @SL_KM = CASE WHEN @SoLuongMua <= 3 THEN @SoLuongMua ELSE 3 END;
                    SET @SL_Goc = @SoLuongMua - @SL_KM;
                    SET @ThanhTien = (@SL_KM * @GiaSale) + (@SL_Goc * @GiaNiemYet);
                    UPDATE KHUYENMAI SET SoLuongToiDa = SoLuongToiDa - @SL_KM WHERE MaKhuyenMai = @MaKhuyenMai;
                END
                ELSE
                BEGIN
                    SET @ThanhTien = @SoLuongMua * @GiaNiemYet;
                END

                UPDATE SANPHAM SET TonKho = TonKho - @SoLuongMua WHERE MaSanPham = @MaSanPham;
                SET @TongTien = @TongTien + @ThanhTien;

                FETCH NEXT FROM cur_ChiTiet INTO @MaSanPham, @SoLuongMua;
            END

            CLOSE cur_ChiTiet;
            DEALLOCATE cur_ChiTiet;

            UPDATE DONHANG SET ThanhTien = @TongTien WHERE MaDonHang = @MaDonHang;

            COMMIT TRANSACTION;
            PRINT '>>> T2 [THANH CONG]: Khong Lost Update nho cho T1 xong truoc';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF CURSOR_STATUS('local', 'cur_ChiTiet') >= 0
            BEGIN
                CLOSE cur_ChiTiet;
                DEALLOCATE cur_ChiTiet;
            END
            PRINT '>>> T2 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- =========================================================================
    -- KỊCH BẢN 2: HỖ TRỢ TEST PHANTOM READ
    -- Procedure này chạy để INSERT đơn hàng mới trong khi sp_ThongKe đang chạy
    -- Nếu ThongKe dùng SERIALIZABLE, proc này sẽ bị block
    -- =========================================================================
    ELSE IF @KichBan = 2
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T2 [BAT DAU]: Xu ly don hang (trong khi ThongKe dang chay)';

            -- Process order normally
            DECLARE cur_ChiTiet2 CURSOR FOR
                SELECT MaSanPham, SoLuong FROM CHITIET_DONHANG WHERE MaDonHang = @MaDonHang;

            OPEN cur_ChiTiet2;
            FETCH NEXT FROM cur_ChiTiet2 INTO @MaSanPham, @SoLuongMua;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GiaNiemYet = GiaNiemYet FROM SANPHAM WHERE MaSanPham = @MaSanPham;
                SET @ThanhTien = @SoLuongMua * @GiaNiemYet;
                
                UPDATE SANPHAM SET TonKho = TonKho - @SoLuongMua WHERE MaSanPham = @MaSanPham;
                SET @TongTien = @TongTien + @ThanhTien;

                FETCH NEXT FROM cur_ChiTiet2 INTO @MaSanPham, @SoLuongMua;
            END

            CLOSE cur_ChiTiet2;
            DEALLOCATE cur_ChiTiet2;

            -- This UPDATE will be BLOCKED if ThongKe uses SERIALIZABLE
            PRINT '>>> T2 [CAP NHAT]: Cap nhat ThanhTien cho don hang...';
            UPDATE DONHANG SET ThanhTien = @TongTien WHERE MaDonHang = @MaDonHang;

            COMMIT TRANSACTION;
            PRINT '>>> T2 [THANH CONG]: Da xu ly xong (Sau khi ThongKe cho phep)';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF CURSOR_STATUS('local', 'cur_ChiTiet2') >= 0
            BEGIN
                CLOSE cur_ChiTiet2;
                DEALLOCATE cur_ChiTiet2;
            END
            PRINT '>>> T2 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

/*******************************************************************************
* PROCEDURE 3: sp_ThongKe_TongQuan_NgayHienTai
* Description: Generate daily statistics - customer count and revenue
* KichBan 1: Fix PHANTOM READ using SERIALIZABLE isolation
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_ThongKe_TongQuan_NgayHienTai
    @KichBan INT = 1 -- 1: Fix Phantom Read
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @SL_Khach_Lan1 INT;
    DECLARE @DoanhThu_Lan1 DECIMAL(18,2);
    DECLARE @SL_Khach_Lan2 INT;
    DECLARE @DoanhThu_Lan2 DECIMAL(18,2);
    DECLARE @NgayHienTai DATE = CAST(GETDATE() AS DATE);

    -- =========================================================================
    -- KỊCH BẢN 1: XỬ LÝ PHANTOM READ
    -- Vấn đề: T1 đọc lần 1, T2 insert đơn hàng mới, T1 đọc lần 2 thấy "bóng ma"
    -- Giải pháp: Sử dụng SERIALIZABLE để khóa cả phạm vi dữ liệu
    -- =========================================================================
    IF @KichBan = 1
    BEGIN
        -- [GIẢI THÍCH]: SERIALIZABLE sử dụng Key-Range Lock
        -- Khóa toàn bộ phạm vi rows thỏa mãn WHERE (tất cả đơn hàng ngày hôm nay)
        -- Không ai được INSERT/UPDATE rows mới vào phạm vi này
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

        BEGIN TRY
            BEGIN TRANSACTION;
            
            PRINT '>>> T1 [DOC LAN 1]: Thong ke voi SERIALIZABLE (khoa pham vi)';
            SELECT @SL_Khach_Lan1 = COUNT(DISTINCT MaKhachHang),
                   @DoanhThu_Lan1 = ISNULL(SUM(ThanhTien), 0)
            FROM DONHANG
            WHERE CAST(NgayLap AS DATE) = @NgayHienTai;

            PRINT '    So khach lan 1: ' + CAST(@SL_Khach_Lan1 AS VARCHAR);
            PRINT '    Doanh thu lan 1: ' + CAST(@DoanhThu_Lan1 AS VARCHAR);

            PRINT '>>> T1 [DANG CHO 15s]: Khong ai duoc INSERT don hang moi vao ngay nay...';
            WAITFOR DELAY '00:00:15';

            PRINT '>>> T1 [DOC LAN 2]: Kiem tra lai (phai giong het lan 1)';
            SELECT @SL_Khach_Lan2 = COUNT(DISTINCT MaKhachHang),
                   @DoanhThu_Lan2 = ISNULL(SUM(ThanhTien), 0)
            FROM DONHANG
            WHERE CAST(NgayLap AS DATE) = @NgayHienTai;

            PRINT '    So khach lan 2: ' + CAST(@SL_Khach_Lan2 AS VARCHAR);
            PRINT '    Doanh thu lan 2: ' + CAST(@DoanhThu_Lan2 AS VARCHAR);

            -- Verify no phantom occurred
            IF @SL_Khach_Lan1 = @SL_Khach_Lan2 AND @DoanhThu_Lan1 = @DoanhThu_Lan2
                PRINT '>>> T1 [KET QUA]: KHONG CO BONG MA - Du lieu nhat quan!';
            ELSE
                PRINT '>>> T1 [CANH BAO]: Phat hien Phantom Read!';

            COMMIT TRANSACTION;
            
            -- Return final statistics
            SELECT @SL_Khach_Lan1 AS SoLuongKhachHang, 
                   @DoanhThu_Lan1 AS TongDoanhThu,
                   @NgayHienTai AS NgayThongKe;
                   
            PRINT '>>> T1 [THANH CONG]: Da thong ke xong, du lieu duoc bao ve.';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

PRINT N'=== ĐÃ TẠO XONG 3 STORED PROCEDURES VỚI CƠ CHẾ CHỐNG XUNG ĐỘT ===';

PRINT N'1. sp_XuLyDonHangThanhVien: @KichBan 1=Fix Lost Update, 2=Fix Deadlock';

PRINT N'2. sp_XuLyDonHangVangLai: @KichBan 1=Fix Lost Update, 2=Support Phantom test';

PRINT N'3. sp_ThongKe_TongQuan_NgayHienTai: @KichBan 1=Fix Phantom Read';
GO