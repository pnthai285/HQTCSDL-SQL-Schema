# Hướng Dẫn Demo Chống Xung Đột - Procedures Tuan

**Nguyên tắc chung:**
1. Luôn chạy `data.sql` trước để Reset dữ liệu
2. Mở 2 cửa sổ query riêng biệt (Tab 1 và Tab 2)
3. Bật tab **Messages** để theo dõi tiến độ

---

## KỊCH BẢN 1: FIX LOST UPDATE

**Cặp Procedure:** `sp_XuLyDonHangThanhVien` (T1) & `sp_XuLyDonHangVangLai` (T2)

**Giải pháp:** Sử dụng `WITH (UPDLOCK)` để khóa dòng KHUYENMAI trước khi đọc

### Các bước:

1. **Chuẩn bị:** Chạy `data.sql`

2. **Cửa sổ 1 (T1):**
```sql
USE DB_TranhChapDongThoi;
-- T1 giữ UPDLOCK trên FlashSale và chờ 10s
EXEC sp_XuLyDonHangThanhVien @MaDonHang = 'DH_LU_T1', @MaKhachHang = 'KH_LU_MEMBER', @KichBan = 1;
```

3. **Cửa sổ 2 (T2):** Chạy NGAY sau T1
```sql
USE DB_TranhChapDongThoi;
-- T2 cũng đòi UPDLOCK trên cùng FlashSale
EXEC sp_XuLyDonHangVangLai @MaDonHang = 'DH_LU_T2', @KichBan = 1;
```

4. **Quan sát:**
   - T1: In `DANG CHO 10s` và đang xử lý
   - T2: **BỊ TREO** - chờ T1 nhả khóa
   - Sau 10s: T1 commit, T2 tiếp tục và thành công

5. **Kiểm tra:**
```sql
SELECT MaKhuyenMai, SoLuongToiDa FROM KHUYENMAI WHERE MaKhuyenMai = 'KM_FLASH_LU';
-- Kết quả đúng: 10 - 2 - 3 = 5 (không mất update)
```

---

## KỊCH BẢN 2: FIX DEADLOCK

**Cặp Procedure:** `sp_XuLyDonHangThanhVien` (T1) & `sp_XuLyDonHangThanhVien` (T2)

**Giải pháp:** Xử lý sản phẩm theo THỨ TỰ NHẤT QUÁN (`ORDER BY MaSanPham`)

### Các bước:

1. **Chuẩn bị:** Chạy `data.sql`

2. **Cửa sổ 1 (T1):**
```sql
USE DB_TranhChapDongThoi;
-- T1 xử lý theo thứ tự: SP_DL_X -> SP_DL_Y
EXEC sp_XuLyDonHangThanhVien @MaDonHang = 'DH_DEADLOCK_T1', @MaKhachHang = 'KH_LU_MEMBER', @KichBan = 2;
```

3. **Cửa sổ 2 (T2):** Chạy NGAY sau T1
```sql
USE DB_TranhChapDongThoi;
-- T2 CŨNG xử lý theo thứ tự: SP_DL_X -> SP_DL_Y (không phải Y->X)
EXEC sp_XuLyDonHangThanhVien @MaDonHang = 'DH_DEADLOCK_T2', @MaKhachHang = 'KH_DL_MEMBER2', @KichBan = 2;
```

4. **Quan sát:**
   - T1 và T2 đều xử lý theo thứ tự ABC
   - T2 chờ T1 xong sản phẩm X mới được xử lý X
   - **KHÔNG CÓ DEADLOCK** - chỉ có blocking tuần tự

---

## KỊCH BẢN 3: FIX PHANTOM READ

**Cặp Procedure:** `sp_ThongKe_TongQuan_NgayHienTai` (T1) & `sp_XuLyDonHangVangLai` (T2)

**Giải pháp:** Sử dụng `SERIALIZABLE` để khóa cả phạm vi dữ liệu

### Các bước:

1. **Chuẩn bị:** Chạy `data.sql`

2. **Cửa sổ 1 (T1):**
```sql
USE DB_TranhChapDongThoi;
-- T1 thống kê với SERIALIZABLE, chờ 15s
EXEC sp_ThongKe_TongQuan_NgayHienTai @KichBan = 1;
```

3. **Cửa sổ 2 (T2):** Chạy NGAY sau T1
```sql
USE DB_TranhChapDongThoi;
-- T2 cố xử lý đơn hàng mới (sẽ thay đổi ThanhTien)
EXEC sp_XuLyDonHangVangLai @MaDonHang = 'DH_PHANTOM_NEW', @KichBan = 2;
```

4. **Quan sát:**
   - T1: Đọc lần 1, in số khách và doanh thu
   - T2: **BỊ TREO** - không thể UPDATE DONHANG vì T1 khóa phạm vi
   - T1: Đọc lần 2 - **KẾT QUẢ GIỐNG LẦN 1** (không có bóng ma)
   - T1 commit, T2 mới được chạy

---

## Tổng Kết Giải Pháp

| Xung Đột | Giải Pháp | SQL Technique |
|----------|-----------|---------------|
| Lost Update | Khóa dòng trước khi đọc | `WITH (UPDLOCK)` |
| Deadlock | Xử lý theo thứ tự cố định | `ORDER BY` + `UPDLOCK` |
| Phantom Read | Khóa cả phạm vi dữ liệu | `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` |
