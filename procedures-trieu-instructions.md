**Nguyên tắc chung cho mọi bài test:**
1.  **Reset dữ liệu:** Luôn chạy file `FILE 2: DATA SEEDING` (đoạn script Insert dữ liệu) trước mỗi kịch bản để đảm bảo dữ liệu sạch.
2.  **Môi trường:** Mở các cửa sổ query (New Query) riêng biệt trong SQL Server (Tab 1, Tab 2, Tab 3).
3.  **Theo dõi:** Luôn bật tab **Messages** (Thông báo) ở dưới cùng để xem các dòng `PRINT` trạng thái thay vì chỉ nhìn tab Results.

---

### KỊCH BẢN 1: KIỂM TRA LOST UPDATE (Cập nhật bị mất)

**Mục tiêu:** Chứng minh khi có một giao tác đang giữ khóa cập nhật (User 1), giao tác khác (User 2) buộc phải xếp hàng chờ đợi chứ không được phép đọc dữ liệu cũ rồi ghi đè sai lệch.

1.  **Chuẩn bị:** Chạy script Data Seeding (Tồn kho SP001 = 100).
2.  **Cửa sổ 1 (Giả lập User 1 đang thao tác):** Copy và chạy lệnh sau (F5):
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    
    -- Mở giao dịch và chiếm khóa X nhưng KHÔNG COMMIT NGAY
    BEGIN TRANSACTION;
    
    -- Update "giả" để giữ chỗ (X-Lock)
    UPDATE SANPHAM 
    SET TonKho = TonKho 
    WHERE MaSanPham = 'SP001';
    
    PRINT '>> [Tab 1] Đang giữ khóa X trên SP001. Đừng Commit vội!';
    ```
3.  **Cửa sổ 2 (User 2 nhập kho thật):** **NGAY LẬP TỨC** chạy lệnh sau:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    
    DECLARE @List ChiTietNhapTableType;
    INSERT INTO @List VALUES ('DH_LU_01', 'SP001', 50, 15000);
    
    PRINT '>> [Tab 2] Bắt đầu yêu cầu nhập kho...';
    EXEC sp_Tao_PhieuNhapKho @MaNhanVien='NV01', @ChiTietNhap=@List;
    ```
4.  **Quan sát hiện tượng:**
    * **Cửa sổ 2:** Hiện trạng thái **"Executing query..."** (xoay vòng tròn) và không hiện kết quả ngay.
    * **Giải thích:** Tab 2 đã bị chặn (Blocking) đúng như mong đợi để bảo vệ dữ liệu.
5.  **Kết thúc test:**
    * Quay lại **Cửa sổ 1**, bôi đen và chạy dòng lệnh: `COMMIT;`
    * Ngay lập tức **Cửa sổ 2** sẽ báo thành công.
6.  **Kiểm tra kết quả cuối cùng:**
    ```sql
    SELECT MaSanPham, TonKho FROM SANPHAM WHERE MaSanPham = 'SP001';
    ```
    * **Kết quả đúng:** TonKho = `150` (100 gốc + 50 nhập).
    * **Ý nghĩa:** Dữ liệu được bảo toàn, không bị ghi đè.

---

### KỊCH BẢN 2: KIỂM TRA UNREPEATABLE READ (Hệ thống tính toán sai)

**Mục tiêu:** Chứng minh khi Hệ thống đang tính toán kiểm tra hàng hóa (giữ khóa S), Nhân viên nhập kho không thể chen ngang sửa đổi dữ liệu làm sai lệch quyết định của hệ thống.

1.  **Chuẩn bị:** Chạy script Data Seeding (Tồn kho SP002 = 60, Đơn hàng chờ nhập 100).
2.  **Cửa sổ 1 (Giả lập Hệ thống Auto):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    
    -- Thiết lập mức cô lập cao để giữ khóa S
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
    BEGIN TRANSACTION;
    
    -- Đọc dữ liệu và GIỮ KHÓA S
    SELECT MaSanPham, TonKho FROM SANPHAM WHERE MaSanPham = 'SP002';
    
    PRINT '>> [Tab 1] Hệ thống đang đọc SP002. Đừng Commit vội!';
    ```
3.  **Cửa sổ 2 (Nhân viên nhập kho):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    
    DECLARE @List ChiTietNhapTableType;
    INSERT INTO @List VALUES ('DH_UR_01', 'SP002', 100, 20000);
    
    PRINT '>> [Tab 2] Cố gắng nhập kho chen ngang...';
    EXEC sp_Tao_PhieuNhapKho @MaNhanVien='NV02', @ChiTietNhap=@List;
    ```
4.  **Quan sát hiện tượng:**
    * **Cửa sổ 2:** Bị treo (Blocked).
    * **Giải thích:** Hệ thống (Tab 1) đang đảm bảo rằng "Trong lúc tôi đang tính toán, không ai được sửa dữ liệu này".
5.  **Kết thúc test:**
    * Quay lại **Cửa sổ 1**, chạy lệnh: `COMMIT;`
    * **Cửa sổ 2** sẽ chạy xong ngay sau đó.

---

### KỊCH BẢN 3: KIỂM TRA DEADLOCK (Đã chuyển thành Blocking)

**Mục tiêu:** Chứng minh T1 và T2 không còn bị lỗi Deadlock (Error 1205 màu đỏ), mà sẽ xếp hàng tuần tự nhờ kỹ thuật `UPDLOCK` và thứ tự truy cập tài nguyên hợp lý.

1.  **Chuẩn bị:** Chạy script Data Seeding (Reset lại SP003 và DH_DL_01).
2.  **Cửa sổ 1 (Giả lập giao tác treo):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    
    BEGIN TRANSACTION;
    -- Giữ khóa X trên Đơn hàng DH_DL_01
    UPDATE DONDATHANG_NSX SET TrangThai = TrangThai WHERE MaDonDatHang = 'DH_DL_01';
    
    PRINT '>> [Tab 1] Đang giữ Đơn hàng. Đừng Commit vội!';
    ```
3.  **Cửa sổ 2 (Hệ thống Kiểm tra):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    PRINT '>> [Tab 2] Hệ thống bắt đầu kiểm tra...';
    EXEC sp_KiemTra_DatHangTuDong; 
    -- Sẽ bị treo vì cần đọc Đơn hàng mà Tab 1 đang giữ
    ```
4.  **Cửa sổ 3 (Nhân viên Nhập kho):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    GO
    DECLARE @List ChiTietNhapTableType;
    INSERT INTO @List VALUES ('DH_DL_01', 'SP003', 50, 50000);
    
    PRINT '>> [Tab 3] Nhân viên bắt đầu nhập kho...';
    EXEC sp_Tao_PhieuNhapKho @MaNhanVien='NV01', @ChiTietNhap=@List;
    -- Sẽ bị treo vì cần Update Đơn hàng mà Tab 1 đang giữ
    ```
5.  **Quan sát hiện tượng (QUAN TRỌNG):**
    * Cả **Tab 2** và **Tab 3** đều quay vòng (Executing...).
    * **KHÔNG CÓ LỖI MÀU ĐỎ** (Deadlock Victim) xuất hiện. Đây là thành công!
6.  **Kết thúc test:**
    * Quay lại **Cửa sổ 1**, chạy lệnh: `COMMIT;`
    * Lần lượt Tab 2 và Tab 3 sẽ được giải phóng và hoàn thành (Success).