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

        -- [BƯỚC 1]: Kiểm tra và Khóa chặt (XLOCK)
        -- KỸ THUẬT FIX: WITH (XLOCK, ROWLOCK)
        -- Tác dụng: Khóa độc quyền ngay lập tức. T2 (Update) dù chỉ đọc hay sửa đều phải chờ.
        -- Điều này ngăn T2 đọc dữ liệu mà T1 "đang định xóa nhưng chưa xóa hẳn".
        IF NOT EXISTS (SELECT 1 FROM SANPHAM WITH (XLOCK, ROWLOCK) WHERE MaSanPham = @MaSP)
        BEGIN
            PRINT '>>> T1: San pham khong ton tai.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- [BƯỚC 2]: Giả lập giữ khóa (Wait 10s)
        PRINT '>>> T1: Da giu XLOCK. Dang kiem tra rang buoc (Wait 10s)...';
        WAITFOR DELAY '00:00:10';

        -- [BƯỚC 3]: Xóa thật
        DELETE FROM SANPHAM WHERE MaSanPham = @MaSP;

        PRINT '>>> T1: Da xoa xong. Commit transaction.';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT '>>> LOI HE THONG: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

USE DB_TranhChapDongThoi;
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
        VALUES (@MaSP, @TenSP, 100000, 100, 'NSX01', 'DM01'); 
        -- (Lưu ý: Bạn cần đảm bảo NSX01 và DM01 có trong DB hoặc sửa lại cho khớp data của bạn)

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