# Hướng Dẫn Demo Chống Xung Đột - Procedures-thang

**Nguyên tắc chung cho mọi bài test:**

1. **Chuẩn bị dữ liệu :** Luôn chạy script reset dữ liệu trước khi thực hiện để đảm bảo trạng thái sạch (Ví dụ: Sản phẩm `SP01` có `tồn kho = 100` ).

2. **Môi trường thực thi :**: Mở 2 cửa sổ query riêng biệt (Tab 1 cho Giao tác T1 và Tab 2 cho Giao tác T2).

3. **Theo dõi :** Quan sát tab **Messages** để xem tiến trình thực thi và các lệnh `PRINT` từ Procedure.


## KỊCH BẢN 1: KHẮC PHỤC LỖI MẤT DỮ LIỆU CẬP NHẬT (Lost Update Fix)

**Mục tiêu :** Chứng minh việc sử dụng UPDLOCK giúp T2 không đọc dữ liệu tồn kho cũ trong khi T1 đang xử lý. Đảm bảo tồn kho giảm chính xác từ 100 xuống 90 thay vì bị ghi đè thành 95.


## Các bước thực hiện : 


1. **Chuẩn bị :** Đảm bảo sản phẩm `SP010` có `TonKho = 100`; Có tồn tại đơn hàng `DH010`, `DH011`.

2. **Cửa sổ 1 (T1) :** Thực hiện thêm chi tiết cho đơn hàng `DH010`:

```SQL

EXEC sp_ThemChiTietDonHang @MaDH = 'DH010', @MaSP = 'SP010', @SoLuong = 5;
```

3. **Cửa sổ 2 (T2) :** NGAY LẬP TỨC chạy lệnh mua thêm cho đơn hàng `DH011`:
```SQL
EXEC sp_ThemChiTietDonHang @MaDH = 'DH011', @MaSP = 'SP010', @SoLuong = 5;
```

**Quan sát hiện tượng :**
**Cửa sổ 2 :** Sẽ bị TREO (WAITING) ngay tại bước đọc tồn kho vì T1 đang giữ khóa UPDLOCK trên dòng sản phẩm đó, sau khi T1 hoàn thành thì sẽ tiếp tục thực hiện

**Kiểm tra tồn kho** (Kỳ vọng: 90)
~~~SQL
SELECT MaSanPham, TonKho FROM SANPHAM WHERE MaSanPham = 'SP010';
~~~

**Kết quả :** Sau khi T1 hoàn tất và Commit, T2 mới bắt đầu đọc số lượng mới (95) và tiếp tục trừ xuống 90.

**Kết luận :** Tồn kho cuối cùng là 90. Lỗi Lost Update đã được xử lý thành công.


## KỊCH BẢN 2: KHẮC PHỤC LỖI ĐỌC BÓNG MA (Phantom Read Fix)

**Mục tiêu :** Chứng minh mức cô lập `SERIALIZABLE ` thực hiện khóa phạm vi (Range Lock), ngăn T2 chèn trùng mã đơn hàng khi T1 đang trong quá trình kiểm tra.

## Các bước thực hiện : 

1. **Chuẩn bị :** Đảm bảo mã đơn hàng `DH100` chưa tồn tại trong bảng DONHANG.

2. **Cửa sổ 1 (T1) :** Thực hiện tạo đơn hàng `DH100`:

```SQL

EXEC sp_TaoDonHang @MaDH = 'DH100', @MaKH = 'KH010', @NgayDat = '2025-12-30', @HinhThuc = N'Online', @TrangThai = N'Mới';
```

3. **Cửa sổ 2 (T2) :** NGAY LẬP TỨC chạy lệnh tạo cùng mã đơn hàng `DH100`:

```SQL

EXEC sp_TaoDonHang @MaDH = 'DH100', @MaKH = 'KH010', @NgayDat = '2025-12-30', @HinhThuc = N'Tại chỗ', @TrangThai = N'Mới';
```

**Quan sát hiện tượng :**
**Cửa sổ 2 :** Bị TREO do T1 đã đặt khóa phạm vi lên bảng DONHANG.

**Kiểm tra đơn hàng** (Kỳ vọng: Chỉ có 1 mã DH100)
~~~SQL
SELECT MaDonHang FROM DONHANG WHERE MaDonHang = 'DH100';
~~~

**Kết quả :** Sau khi T1 hoàn tất chèn dữ liệu, T2 mới chạy tiếp bước kiểm tra, thấy mã đã tồn tại và báo lỗi "Mã đơn hàng đã tồn tại".


**Kết luận :** Ngăn chặn thành công 2 giao tác cùng chèn trùng một khóa chính do hiện tượng đọc bóng ma.

## KỊCH BẢN 3: KHẮC PHỤC LỖI KHÓA CHẾT (Deadlock Fix)

**Mục tiêu :** Chứng minh việc sử dụng `UPDLOCK` ngay từ bước đọc đầu tiên giúp ngăn chặn tình trạng hai giao tác cùng giữ khóa Shared (S) rồi chờ nâng cấp lên khóa `Exclusive` (X) gây ra Deadlock.

## Các bước thực hiện : 

1. **Chuẩn bị :** Đơn hàng `DH_DEAD` có `ThanhTien = 1000000`.

2. **Cửa sổ 1 (T1) :** Áp dụng phiếu giảm giá cho đơn hàng:

```SQL

EXEC sp_ApDungPhieuGiamGia @MaDH = 'DH_DEAD', @MaKH = 'KH010';
```
3. **Cửa sổ 2 (T2) :** NGAY LẬP TỨC chạy cùng lệnh cho đơn hàng đó:

```SQL

EXEC sp_ApDungPhieuGiamGia @MaDH = 'DH_DEAD', @MaKH = 'KH010';
```

**Quan sát hiện tượng :**
**Cửa sổ 2 :** Sẽ ĐỨNG IM xếp hàng đợi T1 xong. Hệ thống không còn báo lỗi đỏ "Deadlock victim" như trước.

**Kiểm tra tiền đơn hàng** (Kỳ vọng: 900,000 nếu ban đầu 1,000,000)
~~~SQL
SELECT MaDonHang, ThanhTien FROM DONHANG WHERE MaDonHang = 'DH_DEAD';
~~~

**Kết quả :** T1 cập nhật tiền thành công. T2 sau đó thực hiện nhưng sẽ báo không tìm thấy phiếu giảm giá (vì phiếu đã bị T1 dùng).

**Kết luận :** Xử lý thành công Deadlock, đảm bảo các giao tác thực hiện tuần tự và an toàn.
