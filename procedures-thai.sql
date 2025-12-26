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