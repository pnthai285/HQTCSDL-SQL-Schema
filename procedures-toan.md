# Hướng Dẫn Demo Chống Xung Đột - Quản Lý Sản Phẩm

**Nguyên tắc chung:**
1.  **Dữ liệu:** Đảm bảo Database đã có dữ liệu mẫu (Sản phẩm `SP001`, `NSX01`, `DM01`).
2.  **Môi trường:** Mở 2 cửa sổ query riêng biệt (Tab 1 và Tab 2) trong SQL Server Management Studio (SSMS).
3.  **Theo dõi:** Bật tab **Messages** để theo dõi thông báo `PRINT` từ hệ thống.

---

## KỊCH BẢN 1: FIX LOST UPDATE & DEADLOCK
**Mô tả:** Hai người cùng xem tồn kho (S-Lock) rồi cùng cập nhật (X-Lock).
* **Vấn đề:** Deadlock chuyển đổi hoặc Lost Update.
* **Giải pháp:** Sử dụng `WITH (UPDLOCK)` để "xí chỗ" quyền ghi ngay khi đọc.
* **Procedure sử dụng:** `sp_Update_SanPham`

### Các bước thực hiện:

1.  **Chuẩn bị:** Reset tồn kho `SP001` về 100.
    ```sql
    UPDATE SANPHAM SET TonKho = 100 WHERE MaSanPham = 'SP001';
    ```

2.  **Cửa sổ 1 (T1 - Người đến trước):**
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 mua 10 cái, giữ khóa UPDLOCK và chờ 10s
    EXEC sp_Update_SanPham @MaSP = 'SP001', @SoLuongMua = 10, @Role = 'T1';
    ```

3.  **Cửa sổ 2 (T2 - Người đến sau):** *Chạy NGAY sau khi bấm T1*
    ```sql
    USE DB_TranhChapDongThoi;
    -- T2 mua 20 cái. Sẽ bị CHẶN (WAITING) ngay lập tức
    EXEC sp_Update_SanPham @MaSP = 'SP001', @SoLuongMua = 20, @Role = 'T2';
    ```

4.  **Kết quả mong đợi:**
    * **T1:** Đếm ngược 10s -> Update thành công (Kho còn 90).
    * **T2:** Bị treo trong lúc T1 chạy -> Ngay khi T1 xong -> T2 chạy tiếp -> Đọc được tồn kho 90 -> Trừ 20 -> Update thành công (Kho còn 70).

---

## KỊCH BẢN 2: FIX DIRTY READ (Xóa vs Cập Nhật)
**Mô tả:** T1 đang xóa sản phẩm, T2 nhảy vào đọc/sửa dữ liệu đó.
* **Vấn đề:** T2 thao tác trên dữ liệu rác (Dirty Read).
* **Giải pháp:** Sử dụng `WITH (XLOCK)` trong lệnh xóa để cấm mọi truy cập.
* **Procedure sử dụng:** `sp_Delete_SanPham` (T1) & `sp_Update_SanPham` (T2)

### Các bước thực hiện:

1.  **Chuẩn bị:** Đảm bảo `SP001` đang tồn tại.

2.  **Cửa sổ 1 (T1 - Đang xóa):**
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 khóa độc quyền (XLOCK), giả lập kiểm tra lâu (10s)
    EXEC sp_Delete_SanPham @MaSP = 'SP001', @Role = 'T1';
    ```

3.  **Cửa sổ 2 (T2 - Cố gắng cập nhật):** *Chạy NGAY sau T1*
    ```sql
    USE DB_TranhChapDongThoi;
    -- T2 cố đọc SP001 để cập nhật
    EXEC sp_Update_SanPham @MaSP = 'SP001', @SoLuongMua = 5, @Role = 'T2';
    ```

4.  **Kết quả mong đợi:**
    * **T1:** Giữ khóa XLOCK 10s.
    * **T2:** Bị treo (Blocking).
    * **Sau 10s:** T1 Xóa xong. T2 được thả -> Không tìm thấy dữ liệu -> Báo lỗi "Sản phẩm không tồn tại".

---

## KỊCH BẢN 3: FIX RACE CONDITION (Tranh Chấp Insert)
**Mô tả:** T1 và T2 cùng kiểm tra thấy mã "SP_NEW" chưa tồn tại, cùng Insert.
* **Vấn đề:** Trùng Khóa Chính (PK Violation) hoặc Phantom Insert.
* **Giải pháp:** Sử dụng `WITH (UPDLOCK, HOLDLOCK)` để khóa phạm vi (Range Lock).
* **Procedure sử dụng:** `sp_Add_SanPham`

### Các bước thực hiện:

1.  **Chuẩn bị:** Xóa `SP_NEW` nếu đã có.
    ```sql
    DELETE FROM SANPHAM WHERE MaSanPham = 'SP_NEW';
    ```

2.  **Cửa sổ 1 (T1 - Người giữ chỗ):**
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 kiểm tra mã, giữ Range Lock "hố trống" trong 10s
    EXEC sp_Add_SanPham @MaSP = 'SP_NEW', @TenSP = N'Sp T1', @Role = 'T1';
    ```

3.  **Cửa sổ 2 (T2 - Người chen ngang):** *Chạy NGAY sau T1*
    ```sql
    USE DB_TranhChapDongThoi;
    -- T2 cố gắng chèn SP_NEW
    EXEC sp_Add_SanPham @MaSP = 'SP_NEW', @TenSP = N'Sp T2', @Role = 'T2';
    ```

4.  **Kết quả mong đợi:**
    * **T1:** Giữ khóa Range Lock.
    * **T2:** Bị treo ngay lập tức.
    * **T1:** Insert xong.
    * **T2:** Được thả -> Kiểm tra lại thấy "Đã tồn tại" -> Báo lỗi & Rollback.