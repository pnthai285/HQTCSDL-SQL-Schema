/*******************************************************************************
* MEMBER: THAI
*******************************************************************************/
USE DB_TranhChapDongThoi;
GO

/*******************************************************************************
* PROCEDURE 1: sp_TaoPhieuGiamGiaSinhNhat (T1)
* MỤC ĐÍCH: Giao tác đọc dữ liệu và xử lý logic (thường là nạn nhân hoặc người giữ khóa)
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_TaoPhieuGiamGiaSinhNhat
    @MaKhachHang VARCHAR(20) = NULL,
    @Thang INT = NULL,
    @KichBan INT -- 1: Fix Deadlock, 2: Fix Unrepeatable, 3: Fix Phantom
AS
BEGIN
    SET NOCOUNT ON;
    
    -- =========================================================================
    -- KỊCH BẢN 1: XỬ LÝ DEADLOCK (CONVERSION DEADLOCK)
    -- Vấn đề cũ: Cùng đọc (S-Lock) -> Cùng chờ nâng cấp lên X-Lock -> Deadlock.
    -- Giải pháp: Sử dụng gợi ý khóa WITH (UPDLOCK).
    -- =========================================================================
    IF @KichBan = 1 
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED; 

        BEGIN TRY
            BEGIN TRANSACTION;
            
            PRINT '>>> T1 [BAT DAU]: Doc du lieu voi WITH (UPDLOCK)';
            
            -- [GIẢI THÍCH]: UPDLOCK đánh dấu rằng "Tôi đọc dòng này để chuẩn bị sửa".
            -- Nó tương thích với S-Lock (cho người khác đọc) nhưng KHÔNG tương thích với UPDLOCK khác.
            -- => Nếu T2 cũng dùng UPDLOCK, T2 sẽ phải xếp hàng chờ ngay tại đây, không được phép đọc.
            -- => Tránh việc cả 2 cùng giữ khóa rồi cùng chờ nhau (Deadlock).
            SELECT HoTen, NgaySinh 
            FROM KHACHHANG WITH (UPDLOCK) 
            WHERE MaKhachHang = @MaKhachHang;

            PRINT '>>> T1 [DA GIU KHOA UPDATE]: Dang xu ly (Wait 15s)...';
            WAITFOR DELAY '00:00:15'; 

            PRINT '>>> T1 [UPDATE]: Thuc hien ghi du lieu...';
            -- Lúc này chuyển từ U-Lock sang X-Lock rất an toàn vì không ai giữ U-Lock khác.
            UPDATE KHACHHANG 
            SET DiaChi = DiaChi + ' (T1 Fix)' 
            WHERE MaKhachHang = @MaKhachHang;

            COMMIT TRANSACTION;
            PRINT '>>> T1 [THANH CONG]: Giao tac hoan tat an toan.';
        END TRY
        BEGIN CATCH
            -- Nếu có lỗi (dù hiếm khi xảy ra Deadlock với cách này), Rollback
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- =========================================================================
    -- KỊCH BẢN 2: XỬ LÝ UNREPEATABLE READ (ĐỌC KHÔNG LẶP LẠI)
    -- Vấn đề cũ: T1 đọc xong nhả khóa ngay. T2 xen vào sửa. T1 tính toán sai với dữ liệu cũ.
    -- Giải pháp: Nâng mức cô lập lên REPEATABLE READ.
    -- =========================================================================
    ELSE IF @KichBan = 2
    BEGIN
        -- [GIẢI THÍCH]: REPEATABLE READ yêu cầu SQL Server giữ khóa S (Shared Lock)
        -- trên tất cả dữ liệu đã đọc cho đến khi Transaction kết thúc.
        -- => T2 muốn Update dòng này sẽ bị chặn (Blocking) cho đến khi T1 xong.
        SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T1 [BAT DAU]: Doc du lieu voi REPEATABLE READ';

            DECLARE @HangTheHienTai NVARCHAR(50);
            
            -- Khóa S được giữ chặt tại dòng này
            SELECT @HangTheHienTai = HangThe 
            FROM THETHANHVIEN 
            WHERE MaKhachHang = @MaKhachHang;

            PRINT '    Hang the doc duoc: ' + ISNULL(@HangTheHienTai, 'NULL');
            PRINT '>>> T1 [DANG CHO 15s]: Bao ve du lieu khoi bi thay doi...';
            
            WAITFOR DELAY '00:00:15';

            PRINT '>>> T1 [TIEP TUC]: Insert phieu giam gia dua tren du lieu nhat quan';
            -- Do T2 bị chặn, @HangTheHienTai vẫn đảm bảo đúng với thực tế trong DB lúc này
            DECLARE @TiLeGiam FLOAT;
            IF @HangTheHienTai = 'Bac' SET @TiLeGiam = 0.1;
            ELSE IF @HangTheHienTai = 'Vang' SET @TiLeGiam = 0.2;
            ELSE SET @TiLeGiam = 0.05;

            INSERT INTO PHIEUGIAMGIA (MaPhieu, TiLeGiamGia, NgayPhatHanh, MaKhachHang, TrangThai)
            VALUES ('PGG_' + CONVERT(VARCHAR(5), GETDATE(), 108), @TiLeGiam, GETDATE(), @MaKhachHang, N'ChuaSuDung');

            COMMIT TRANSACTION;
            PRINT '>>> T1 [THANH CONG]: Da xu ly xong. T2 bay gio moi duoc phep chay.';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- =========================================================================
    -- KỊCH BẢN 3: XỬ LÝ PHANTOM READ (ĐỌC BÓNG MA)
    -- Vấn đề cũ: T1 đọc phạm vi. T3 chèn/sửa dòng lọt vào phạm vi. T1 đọc lại thấy "ma".
    -- Giải pháp: Nâng mức cô lập lên SERIALIZABLE.
    -- =========================================================================
    ELSE IF @KichBan = 3
    BEGIN
        -- [GIẢI THÍCH]: SERIALIZABLE là mức cao nhất. Nó sử dụng Key-Range Lock.
        -- Nó khóa toàn bộ phạm vi dữ liệu thỏa mãn điều kiện WHERE (ví dụ: cả tháng 5).
        -- => Không ai được Insert/Update làm thay đổi số lượng dòng trong phạm vi này.
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; 

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T1 [DOC LAN 1]: Khoa chat pham vi thang ' + CAST(@Thang AS VARCHAR);
            
            SELECT * FROM KHACHHANG WHERE MONTH(NgaySinh) = @Thang;

            PRINT '>>> T1 [DANG CHO 15s]: Khong ai duoc phep tao "Bong ma"';
            WAITFOR DELAY '00:00:15';

            PRINT '>>> T1 [DOC LAN 2]: Kiem tra lai (Ket qua phai giong het lan 1)';
            SELECT * FROM KHACHHANG WHERE MONTH(NgaySinh) = @Thang;

            COMMIT TRANSACTION;
            PRINT '>>> T1 [KET THUC]: Dam bao tinh toan ven du lieu.';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T1 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

/*******************************************************************************
* PROCEDURE 2: sp_CapNhatHangTheThanhVien (T2)
* MỤC ĐÍCH: Giao tác gây nhiễu (Cố gắng sửa đổi dữ liệu khi T1 đang chạy)
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_CapNhatHangTheThanhVien
    @MaKhachHang VARCHAR(20),
    @HangTheMoi NVARCHAR(50) = N'Vang',
    @KichBan INT
AS
BEGIN
    SET NOCOUNT ON;

    -- KỊCH BẢN 1: FIX DEADLOCK
    IF @KichBan = 1
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T2 [BAT DAU]: Cung su dung UPDLOCK';
            
            -- [GIẢI THÍCH]: Vì T1 đã giữ UPDLOCK trước, T2 chạy dòng này sẽ bị TREO (WAITING).
            -- T2 buộc phải chờ T1 Commit xong mới được chạy tiếp.
            -- Điều này biến quá trình song song thành tuần tự -> Không thể Deadlock.
            SELECT HoTen FROM KHACHHANG WITH (UPDLOCK) WHERE MaKhachHang = @MaKhachHang;

            PRINT '>>> T2 [DA CHIEM QUYEN]: (Dong nay chi hien khi T1 da xong)';
            WAITFOR DELAY '00:00:05'; 

            UPDATE KHACHHANG 
            SET DiaChi = DiaChi + ' (T2 Fix)'
            WHERE MaKhachHang = @MaKhachHang;

            COMMIT TRANSACTION;
            PRINT '>>> T2 [THANH CONG]';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T2 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- KỊCH BẢN 2: FIX UNREPEATABLE
    ELSE IF @KichBan = 2
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        
        BEGIN TRY
            BEGIN TRANSACTION;
            PRINT '>>> T2 [BAT DAU]: Co gang Update...';
            
            -- [HỆ QUẢ]: Do T1 dùng REPEATABLE READ, T2 sẽ bị chặn (Blocking) tại đây.
            -- Đây là hành vi đúng để bảo vệ T1.
            UPDATE THETHANHVIEN
            SET HangThe = @HangTheMoi
            WHERE MaKhachHang = @MaKhachHang;

            COMMIT TRANSACTION;
            PRINT '>>> T2 [THANH CONG]: Update thanh cong (Sau khi T1 da xong).';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            PRINT '>>> T2 [LOI]: ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

/*******************************************************************************
* PROCEDURE 3: sp_CapNhatThongTinThanhVien (T3)
* MỤC ĐÍCH: Giao tác gây nhiễu cho Phantom Read
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_CapNhatThongTinThanhVien
    @MaKhachHang VARCHAR(20),
    @NgaySinhMoi DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    
    BEGIN TRY
        BEGIN TRANSACTION;
        PRINT '>>> T3 [BAT DAU]: Co gang thay doi ngay sinh...';
        
        -- [HỆ QUẢ]: Do T1 dùng SERIALIZABLE (Khóa phạm vi), T3 sẽ bị chặn (Blocking)
        -- nếu @NgaySinhMoi rơi vào tháng mà T1 đang khóa.
        UPDATE KHACHHANG
        SET NgaySinh = @NgaySinhMoi
        WHERE MaKhachHang = @MaKhachHang;

        COMMIT TRANSACTION;
        PRINT '>>> T3 [THANH CONG]: Da thay doi ngay sinh (Sau khi T1 ket thuc).';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT '>>> T3 [LOI]: ' + ERROR_MESSAGE();
    END CATCH
END
GO

/*******************************************************************************
* MEMBER: TUAN
*******************************************************************************/
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

/*******************************************************************************
* MEMBER: TOAN
*******************************************************************************/
USE DB_TranhChapDongThoi;
GO

/*******************************************************************************
* PROCEDURE 1: sp_Update_SanPham
* MỤC ĐÍCH: Dùng cho cả T1 và T2 trong kịch bản Update vs Update.
* GIẢI QUYẾT:
* 1. Lost Update: T2 sẽ đọc được dữ liệu mới nhất sau khi T1 commit.
* 2. Deadlock: Tránh việc cả 2 cùng giữ S-Lock rồi chờ X-Lock.
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_Update_SanPham
    @MaSP VARCHAR(20),
    @SoLuongMua INT, -- Số lượng muốn trừ đi
    @Role VARCHAR(2) -- 'T1' (Chạy trước, giữ khóa) hoặc 'T2' (Chạy sau)
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- [BƯỚC 1]: Đọc và Giữ khóa
        -- KỸ THUẬT FIX: Sử dụng WITH (UPDLOCK)
        -- Tác dụng: Báo hiệu "Tôi đọc để sửa". Chỉ 1 người giữ UPDLOCK tại 1 thời điểm.
        -- Nếu T1 giữ UPDLOCK, T2 vào sẽ phải CHỜ (Blocking) ngay tại dòng này -> Không bị Deadlock.
        DECLARE @TonKhoHienTai INT;
        
        IF @Role = 'T1'
            PRINT '>>> T1: Dang doc du lieu voi UPDLOCK...';
        ELSE
            PRINT '>>> T2: Dang co gang doc (se bi block neu T1 dang giu khoa)...';

        SELECT @TonKhoHienTai = TonKho 
        FROM SANPHAM WITH (UPDLOCK, ROWLOCK) 
        WHERE MaSanPham = @MaSP;

        -- Kiểm tra tồn tại
        IF @TonKhoHienTai IS NULL
        BEGIN
            PRINT '>>> Loi: San pham khong ton tai (hoac da bi xoa boi giao tac khac).';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- [BƯỚC 2]: Giả lập thời gian xử lý (Chỉ T1 delay để giữ khóa cho T2 chờ)
        IF @Role = 'T1'
        BEGIN
            PRINT '>>> T1: Da giu UPDLOCK. Dang tinh toan (Wait 10s)...';
            WAITFOR DELAY '00:00:10'; 
        END

        -- [BƯỚC 3]: Kiểm tra logic nghiệp vụ
        IF @TonKhoHienTai < @SoLuongMua
        BEGIN
            PRINT '>>> Loi: Khong du hang ton kho.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- [BƯỚC 4]: Thực hiện Update (Chuyển UPDLOCK -> XLOCK)
        UPDATE SANPHAM
        SET TonKho = @TonKhoHienTai - @SoLuongMua
        WHERE MaSanPham = @MaSP;

        IF @Role = 'T1' PRINT '>>> T1: Update xong. Commit transaction.';
        ELSE PRINT '>>> T2: Update xong (Dua tren du lieu moi nhat).';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT '>>> LOI HE THONG: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

/*******************************************************************************
* PROCEDURE 2: sp_Delete_SanPham
* MỤC ĐÍCH: Dùng cho T1 trong kịch bản Delete vs Update (Dirty Read).
* GIẢI QUYẾT: Dirty Read
* - Sử dụng XLOCK để đảm bảo không ai đọc được dữ liệu rác trước khi Commit.
*******************************************************************************/
USE DB_TranhChapDongThoi;
GO

CREATE OR ALTER PROCEDURE sp_Delete_SanPham
    @MaSP VARCHAR(20),
    @Role VARCHAR(2) = 'T1'
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

    BEGIN TRY
        BEGIN TRANSACTION;

        PRINT '>>> T1 (DELETE): Bat dau giao tac xoa san pham.';

        -- [BƯỚC 1]: Kiểm tra và Khóa chặt (XLOCK) bảng cha (SANPHAM)
        -- KỸ THUẬT FIX: WITH (XLOCK, ROWLOCK)
        -- Ngay lập tức khóa dòng SP lại. Không ai được đọc/sửa dòng này.
        IF NOT EXISTS (SELECT 1 FROM SANPHAM WITH (XLOCK, ROWLOCK) WHERE MaSanPham = @MaSP)
        BEGIN
            PRINT '>>> T1: San pham khong ton tai.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- [BƯỚC 2]: Xóa các dữ liệu ràng buộc khóa ngoại (Child Tables)
        -- Phải thực hiện bước này sau khi đã Lock bảng cha, và trước khi Delete bảng cha.
        IF EXISTS (SELECT 1 FROM SANPHAM_KHUYENMAI WHERE MaSanPham = @MaSP)
        BEGIN
            DELETE FROM SANPHAM_KHUYENMAI WHERE MaSanPham = @MaSP;
            PRINT '>>> T1: Da xoa thong tin lien quan trong SANPHAM_KHUYENMAI.';
        END
        
        -- (Tuỳ chọn: Nếu có ràng buộc ở CHITIET_DONHANG thì cũng phải xử lý ở đây, 
        -- nhưng theo yêu cầu của bạn chỉ tập trung vào SANPHAM_KHUYENMAI).

        -- [BƯỚC 3]: Giả lập giữ khóa (Wait 10s)
        -- Lúc này T1 đang giữ khóa trên SANPHAM (do bước 1) và các dòng đã xóa ở bước 2.
        PRINT '>>> T1: Da giu XLOCK. Dang xu ly logic phuc tap (Wait 10s)...';
        WAITFOR DELAY '00:00:10';

        -- [BƯỚC 4]: Xóa sản phẩm thật (Parent Table)
        DELETE FROM SANPHAM WHERE MaSanPham = @MaSP;

        PRINT '>>> T1: Da xoa xong san pham. Commit transaction.';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT '>>> LOI HE THONG: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

/*******************************************************************************
* PROCEDURE: sp_Add_SanPham
* MỤC ĐÍCH: Demo việc xử lý tranh chấp khi 2 người cùng thêm 1 mã SP.
*******************************************************************************/
CREATE OR ALTER PROCEDURE sp_Add_SanPham
    @MaSP VARCHAR(20),
    @TenSP NVARCHAR(100),
    @Role VARCHAR(2) -- 'T1' (Chạy trước) hoặc 'T2' (Chạy sau)
AS
BEGIN
    SET NOCOUNT ON;
    -- Mặc định SQL Server là Read Committed (Không bảo vệ được Range Lock)
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED; 

    BEGIN TRY
        BEGIN TRANSACTION;

        -- [BƯỚC 1]: KIỂM TRA TỒN TẠI (CRITICAL SECTION)
        -- KỸ THUẬT FIX: WITH (UPDLOCK, HOLDLOCK)
        -- 1. UPDLOCK: "Tôi định sửa/thêm vào đây, ai định sửa thì chờ".
        -- 2. HOLDLOCK (Quan trọng nhất): "Tôi khóa luôn phạm vi này (Key-Range Lock)".
        --    Nếu @MaSP chưa tồn tại, nó khóa luôn "cái hố trống" đó.
        --    Không ai được phép chèn @MaSP vào cái hố đó cho đến khi tôi xong.
        
        IF @Role = 'T1' PRINT '>>> T1: Bat dau kiem tra ton tai...';
        ELSE PRINT '>>> T2: Bat dau kiem tra ton tai...';

        IF EXISTS (SELECT 1 FROM SANPHAM WITH (UPDLOCK, HOLDLOCK) WHERE MaSanPham = @MaSP)
        BEGIN
            PRINT '>>> LOI: Ma san pham da ton tai (Phat hien luc Check).';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- [BƯỚC 2]: GIẢ LẬP ĐỘ TRỄ (Chỉ T1 delay để bẫy T2)
        IF @Role = 'T1'
        BEGIN
            PRINT '>>> T1: Thay Ma SP chua co. Dang giu cho (Wait 10s)...';
            -- Lúc này T1 đang giữ Range-Lock. T2 chạy vào Bước 1 sẽ bị treo ngay lập tức.
            WAITFOR DELAY '00:00:10'; 
        END

        -- [BƯỚC 3]: THỰC HIỆN INSERT
        -- Chỉ chèn các cột cơ bản để demo
        INSERT INTO SANPHAM (MaSanPham, TenSanPham, GiaNiemYet, TonKho, MaNSX, MaDanhMuc)
        VALUES (@MaSP, @TenSP, 100000, 100, 'NSX001', 'DM001'); 
        -- (Lưu ý: Bạn cần đảm bảo NSX001 và DM001 có trong DB hoặc sửa lại cho khớp data của bạn)

        IF @Role = 'T1' PRINT '>>> T1: Insert thanh cong. Commit.';
        ELSE PRINT '>>> T2: Insert thanh cong. Commit.';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        -- Nếu không dùng HOLDLOCK, lỗi này sẽ nổ ra ở T1:
        PRINT '>>> LOI HE THONG (PK Violation): ' + ERROR_MESSAGE();
    END CATCH
END;
GO

/*******************************************************************************
* MEMBER: THANG
*******************************************************************************/
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

/*******************************************************************************
* MEMBER: TRIEU
*******************************************************************************/
USE DB_TranhChapDongThoi;
GO

CREATE TYPE ChiTietNhapTableType AS TABLE (
    MaDonDatHang VARCHAR(20),
    MaSanPham VARCHAR(20),
    SoLuongNhap INT,
    DonGiaNhap DECIMAL(18, 2)
);
GO

CREATE PROCEDURE sp_Tao_PhieuNhapKho
    @MaNhanVien VARCHAR(20),
    @ChiTietNhap ChiTietNhapTableType READONLY
AS
BEGIN
    --Ngăn chặn Lost Update bằng cách giữ khóa lâu hơn
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
    BEGIN TRY 
        BEGIN TRANSACTION;

		--Tạo phiếu nhập kho
        DECLARE @MaPhieuNhap VARCHAR(20) = 'PNK' + FORMAT(GETDATE(), 'yyMMddHHmm');

        INSERT INTO PHIEUNHAPKHO (MaPhieuNhap, NgayNhap, MaNhanVien)
        VALUES (@MaPhieuNhap, GETDATE(), @MaNhanVien);

		--Khai báo biến để duyệt Cursor
        DECLARE @MaDonHang VARCHAR(20), @MaSP VARCHAR(20);
		DECLARE @SoLuongNhap INT;
		DECLARE @DonGia DECIMAL(18, 2);
		DECLARE @TonKhoHienTai INT;

		DECLARE cursor_Nhap CURSOR FOR
		SELECT MaDonDatHang, MaSanPham, SoLuongNhap, DonGiaNhap FROM @ChiTietNhap;

		OPEN cursor_Nhap;
		FETCH NEXT FROM cursor_Nhap INTO @MaDonHang, @MaSP, @SoLuongNhap, @DonGia;

		WHILE @@FETCH_STATUS = 0
		BEGIN
			--Thêm vào chi tiết nhập
			INSERT INTO CHITIET_PHIEUNHAPKHO (MaPhieuNhap, MaSanPham, SoLuongNhap, DonGiaNhap, MaDonDatHang)
			VALUES (@MaPhieuNhap, @MaSP, @SoLuongNhap, @DonGia, @MaDonHang);

			--[Xử lý tranh chấp] Cập nhật tồn kho
			--Dùng UPDLOCK để khóa dòng sản phầm này ngay lập tức
			--Người thứ 2 sẽ phải chờ ngay dòng này -> Không bị Lost Update
			SELECT @TonKhoHienTai = TonKho
			FROM SANPHAM WITH (UPDLOCK)
			WHERE MaSanPham = @MaSP;

			UPDATE SANPHAM
			SET TonKho = ISNULL(@TonKhoHienTai, 0) + @SoLuongNhap
			WHERE MaSanPham = @MaSP;

			--Kiểm tra trạng thái đơn hàng
			--Kiểm tra xem tất cả sản phẩm trong đơn hàng này đã nhập đủ chưa
			IF NOT EXISTS (
				SELECT 1
				FROM CHITIET_DONDATHANG_NSX ct_dat
				WHERE ct_dat.MaDonDatHang = @MaDonHang
				GROUP BY ct_dat.MaSanPham, ct_dat.SoLuongDat
				HAVING ct_dat.SoLuongDat > (
					--Tính tổng đã nhập từ các phiếu nhập trước đó và phiếu này
					SELECT ISNULL(SUM(ct_dat.SoLuongDat), 0)
					FROM CHITIET_PHIEUNHAPKHO ct_nhap
					WHERE ct_nhap.MaDonDatHang = @MaDonHang AND
						  ct_nhap.MaSanPham = ct_dat.MaSanPham
				)
			)
			BEGIN 
				--Nếu không có sản phẩm nào thiếu -> Cập nhật trạng thái
				UPDATE DONDATHANG_NSX
				SET TrangThai = N'Hoàn tất'
				WHERE MaDonDatHang = @MaDonHang;
			END

			FETCH NEXT FROM cursor_Nhap INTO @MaDonHang, @MaSP, @SoLuongNhap, @DonGia;
		END

		CLOSE cursor_Nhap;
		DEALLOCATE cursor_Nhap;

		COMMIT TRANSACTION;
		PRINT N'Nhập kho thành công. Mã phiếu: ' + @MaPhieuNhap;
    END TRY
    BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

		IF CURSOR_STATUS('global', 'cursor_Nhap') >= -1
		BEGIN
			CLOSE cursor_Nhap;
			DEALLOCATE cursor_Nhap;
		END

		DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
		RAISERROR(@ErrorMessage, 16, 1);
    END CATCH
END;
GO

CREATE PROCEDURE sp_KiemTra_DatHangTuDong
AS
BEGIN
	SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

	BEGIN TRY
		BEGIN TRANSACTION;

		DECLARE @MaSP VARCHAR(20);
		DECLARE @TonKho INT, @TonKhoToiDa INT;
		DECLARE @HangDangVe INT, @SoLuongCanDat INT;
		DECLARE @MaNSX VARCHAR(20);
		DECLARE @CountDonDat INT = 0;

		DECLARE cursor_AutoCheck CURSOR FOR
		SELECT MaSanPham, TonKho, TonKhoToiDa, MaNSX FROM SANPHAM;

		OPEN cursor_AutoCheck;
		FETCH NEXT FROM cursor_AutoCheck INTO @MaSP, @TonKho, @TonKhoToiDa, @MaNSX;

		WHILE @@FETCH_STATUS = 0
		BEGIN
			IF @TonKho < (@TonKhoToiDa * 0.7)
			BEGIN
				SELECT @HangDangVe = ISNULL(SUM(ct.SoLuongDat), 0)
				FROM CHITIET_DONDATHANG_NSX ct
				JOIN DONDATHANG_NSX d ON ct.MaDonDatHang = d.MaDonDatHang
				WHERE ct.MaSanPham = @MaSP AND
					  d.TrangThai != N'Hoàn tất';

				SET @SoLuongCanDat = @TonKhoToiDa - @TonKho - @HangDangVe;

				IF @SoLuongCanDat >= (@TonKhoToiDa * 0.1)
				BEGIN
					DECLARE @MaDonNew VARCHAR(20) = 'AUTO' + FORMAT(GETDATE(), 'yyMMddHHmm') + LEFT(@MaSP, 4);

					INSERT INTO DONDATHANG_NSX (MaDonDatHang, NgayDat, TrangThai, MaNhanVien, MaNSX)
					VALUES (@MaDonNew, GETDATE(), N'Chờ xử lý', 'SYSTEM_AUTO', @MaNSX);

					INSERT INTO CHITIET_DONDATHANG_NSX (MaDonDatHang, MaSanPham, SoLuongDat)
					VALUES (@MaDonNew, @MaSP, @SoLuongCanDat);

					SET @CountDonDat = @CountDonDat + 1;
				END
			END

			FETCH NEXT FROM cursor_AutoCheck INTO @MaSP, @TonKho, @TonKhoToiDa, @MaNSX;
		END

		CLOSE cursor_AutoCheck;
		DEALLOCATE cursor_AutoCheck;

		COMMIT TRANSACTION;
		PRINT N'Hệ thống đã tự động tạo ' + CAST(@CountDonDat AS VARCHAR) + N'đơn đặt hàng.';
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

		IF CURSOR_STATUS('global', 'cursor_AutoCheck') >= -1
		BEGIN
			CLOSE cursor_AutoCheck;
			DEALLOCATE cursor_AutoCheck;
		END

		DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
		RAISERROR(@ErrorMessage, 16, 1);
	END CATCH
END;
GO

CREATE PROCEDURE sp_CapNhat_ThongTinKhoHangHoa
	@MaSanPham VARCHAR(20),
	@TonKhoToiDa_Moi INT
AS
BEGIN
	SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

	BEGIN TRY
		BEGIN TRANSACTION;

		DECLARE @TonKhoHienTai INT;

		SELECT @TonKhoHienTai = TonKho
		FROM SANPHAM 
		WHERE MaSanPham = @MaSanPham;

		IF @TonKhoHienTai IS NULL
		BEGIN
			RAISERROR(N'Sản phẩm không tồn tại', 16, 1);
			ROLLBACK TRANSACTION;
			RETURN;
		END

		IF @TonKhoToiDa_Moi < @TonKhoHienTai
		BEGIN
			DECLARE @Message NVARCHAR(20) = N'Lỗi: Sức chứa mới nhỏ hơn tồn kho hiện tại';
			RAISERROR(@Message, 16, 1);
			ROLLBACK TRANSACTION;
			RETURN;
		END

		UPDATE SANPHAM
		SET TonKhoToiDa = @TonKhoToiDa_Moi
		WHERE MaSanPham = @MaSanPham;

		COMMIT TRANSACTION;
		PRINT N'Cập nhật sức chứa tối đa thanh công.';
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
		DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
		RAISERROR(@ErrorMessage, 16, 1);
	END CATCH
END;