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