**Nguyên tắc chung cho mọi bài test:**
1.  Luôn chạy file `data.sql` trước để Reset dữ liệu.
2.  Mở 2 cửa sổ query riêng biệt (Tab 1 và Tab 2).
3.  Luôn bật tab **Messages** (Thông báo) để theo dõi tiến độ thay vì nhìn tab Results.

---

### KỊCH BẢN 1: KIỂM TRA ĐÃ HẾT DEADLOCK (Deadlock Fix)

**Mục tiêu:** Chứng minh T1 và T2 không còn "đấm nhau" chết một người nữa, mà sẽ xếp hàng tuần tự.

1.  **Chuẩn bị:** Chạy file `02_Data.sql`.
2.  **Cửa sổ 1 (T1):** Copy và chạy lệnh sau (F5):
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 giữ quyền UPDLOCK và chờ 15s
    EXEC sp_TaoPhieuGiamGiaSinhNhat @MaKhachHang = 'KH_A', @KichBan = 1;
    ```
3.  **Cửa sổ 2 (T2):** **NGAY LẬP TỨC** chạy lệnh sau:
    ```sql
    USE DB_TranhChapDongThoi;
    -- T2 cũng đòi UPDLOCK
    EXEC sp_CapNhatHangTheThanhVien @MaKhachHang = 'KH_A', @KichBan = 1;
    ```
4.  **Quan sát hiện tượng:**
    *   **Cửa sổ 1:** In ra dòng `Đang chờ 15s...` và đồng hồ đếm giây vẫn chạy.
    *   **Cửa sổ 2:** **SẼ ĐỨNG IM (TREO)**. Biểu tượng thực thi (vòng tròn quay) vẫn quay nhưng không in ra gì cả (hoặc chỉ in dòng `BAT DAU`).
    *   **Sau 15 giây:** Cửa sổ 1 báo `THANH CONG`. Ngay lập tức, Cửa sổ 2 hết treo và cũng báo `THANH CONG`.
5.  **Kết luận:** Đã xử lý Deadlock thành công bằng cơ chế xếp hàng (Queue).

---

### KỊCH BẢN 2: KIỂM TRA DỮ LIỆU NHẤT QUÁN (Unrepeatable Read Fix)

**Mục tiêu:** Chứng minh T1 giữ khóa, không cho T2 sửa đổi dữ liệu trong lúc T1 đang tính toán.

1.  **Chuẩn bị:** Chạy file `02_Data.sql` (Hạng thẻ về 'Bac').
2.  **Cửa sổ 1 (T1):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 đọc thấy 'Bac' và giữ khóa REPEATABLE READ trong 15s
    EXEC sp_TaoPhieuGiamGiaSinhNhat @MaKhachHang = 'KH_A', @KichBan = 2;
    ```
3.  **Cửa sổ 2 (T2):** **NGAY LẬP TỨC** chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    -- T2 cố update lên 'Vang'
    EXEC sp_CapNhatHangTheThanhVien @MaKhachHang = 'KH_A', @HangTheMoi = 'Vang', @KichBan = 2;
    ```
4.  **Quan sát hiện tượng:**
    *   **Cửa sổ 2:** Sẽ bị **TREO** cứng tại dòng lệnh `UPDATE`. Nó không thể sửa dữ liệu vì T1 đang giữ khóa S.
    *   **Cửa sổ 1:** Sau 15s chờ, T1 thực hiện Insert phiếu giảm giá. Vì T2 chưa sửa được, nên T1 vẫn thấy là 'Bac' -> Insert phiếu đúng (0.1). Sau đó T1 Commit.
    *   **Cửa sổ 2:** Ngay khi T1 Commit, T2 được "thả" và thực hiện Update lên 'Vang'.
5.  **Kiểm tra lại dữ liệu:**
    Chạy câu lệnh này để xem kết quả cuối cùng:
    ```sql
    SELECT k.HoTen, t.HangThe, p.TiLeGiamGia 
    FROM KHACHHANG k
    JOIN THETHANHVIEN t ON k.MaKhachHang = t.MaKhachHang
    JOIN PHIEUGIAMGIA p ON k.MaKhachHang = p.MaKhachHang
    WHERE k.MaKhachHang = 'KH_A';
    ```
    *   **Kết quả đúng:** HangThe = `Vang` (Do T2 chạy sau cùng), nhưng TiLeGiamGia = `0.1` (Do T1 tạo phiếu dựa trên hạng Bạc lúc đầu).
    *   **Ý nghĩa:** T1 đã được bảo vệ, làm việc xong xuôi đúng đắn rồi mới cho T2 sửa.

---

### KỊCH BẢN 3: KIỂM TRA KHÔNG CÒN GHOST

**Mục tiêu:** Chứng minh T1 khóa cả phạm vi tháng 5, không cho ai chèn vào tháng 5.

1.  **Chuẩn bị:** Chạy file `02_Data.sql` (KH03 đang ở tháng 4).
2.  **Cửa sổ 1 (T1):** Chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    -- T1 quét tháng 5 (SERIALIZABLE) và chờ 15s
    EXEC sp_TaoPhieuGiamGiaSinhNhat @Thang = 5, @KichBan = 3;
    ```
3.  **Cửa sổ 2 (T3):** **NGAY LẬP TỨC** chạy lệnh:
    ```sql
    USE DB_TranhChapDongThoi;
    -- T3 cố đổi KH03 sang tháng 5
    EXEC sp_CapNhatThongTinThanhVien @MaKhachHang = 'KH03', @NgaySinhMoi = '1992-05-15';
    ```
4.  **Quan sát hiện tượng:**
    *   **Cửa sổ 1:** In ra "Đọc lần 1: Có 2 dòng". Đang chờ...
    *   **Cửa sổ 2:** Bị **TREO**. Dù câu lệnh Update rất đơn giản nhưng không chạy được vì T1 đang khóa cả cái tháng 5 rồi.
    *   **Cửa sổ 1:** Hết 15s, T1 đọc lần 2. **Vẫn chỉ thấy 2 dòng**. -> **KHÔNG CÓ BÓNG MA**. T1 Commit.
    *   **Cửa sổ 2:** Lúc này mới được phép chạy Update.
