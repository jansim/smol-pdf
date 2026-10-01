"""Generates test PDFs covering the kinds of images the engine treats differently.

usage: make_corpus.py <folder>   (needs pikepdf and Pillow)
"""
import io, zlib, random, math, os, sys
import pikepdf
from pikepdf import Pdf, Name, Dictionary, Array, Stream
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = sys.argv[1]
random.seed(1)

def photo(w, h, mode="RGB"):
    # smooth gradients + noise: photographic
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            r = int(128 + 100*math.sin(x/37.0) + random.randint(-20, 20))
            g = int(128 + 100*math.sin(y/23.0 + x/91.0) + random.randint(-20, 20))
            b = int(128 + 90*math.cos((x+y)/51.0) + random.randint(-20, 20))
            px[x, y] = (max(0,min(255,r)), max(0,min(255,g)), max(0,min(255,b)))
    img = img.filter(ImageFilter.GaussianBlur(1))
    return img.convert(mode) if mode != "RGB" else img

def screenshot(w, h):
    img = Image.new("RGB", (w, h), (245, 245, 250))
    d = ImageDraw.Draw(img)
    for i in range(0, h, 40):
        d.rectangle([10, i+5, w-10, i+30], fill=(random.choice([(30,30,30),(200,40,40),(40,120,200)])))
        d.text((20, i+10), "Settings  General  Privacy  " * 3, fill=(255,255,255))
    return img

def scan_bilevel(w, h):
    img = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(img)
    for i in range(60, h-60, 28):
        x = 60
        while x < w - 120:
            ww = random.randint(20, 90)
            d.rectangle([x, i, x+ww, i+16], fill=0)
            x += ww + random.randint(10, 25)
    return img

def new_page(pdf, w=612, h=792):
    pdf.add_blank_page(page_size=(w, h))
    page = pdf.pages[-1]
    page.Resources = Dictionary(XObject=Dictionary())
    return page

def put_image(pdf, page, name, stream, rect, extra=b""):
    page.Resources.XObject[name] = stream
    x, y, w, h = rect
    content = b"q %g 0 0 %g %g %g cm %s Do Q\n" % (w, h, x, y, name.encode()[1:] if False else name.encode())
    content = content.replace(b" Do", b" Do")
    old = page.obj.get("/Contents")
    data = (old.read_bytes() if old is not None else b"") + extra + content
    page.Contents = pdf.make_stream(data)

def jpeg_bytes(img, q=92, **kw):
    b = io.BytesIO(); img.save(b, "JPEG", quality=q, **kw); return b.getvalue()

def img_stream(pdf, data, w, h, cs, bpc=8, filt=None, **extra):
    s = Stream(pdf, data)
    s.Type = Name.XObject; s.Subtype = Name.Image
    s.Width = w; s.Height = h; s.BitsPerComponent = bpc
    if cs is not None: s.ColorSpace = cs
    if filt is not None: s.Filter = filt
    for k, v in extra.items(): s[Name("/" + k)] = v
    return s

def text(pdf, page, s, y=40):
    font = Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica)
    page.Resources.Font = Dictionary(F1=font)
    old = page.obj.get("/Contents")
    data = (old.read_bytes() if old is not None else b"")
    page.Contents = pdf.make_stream(data + b"BT /F1 14 Tf 40 %d Td (%s) Tj ET\n" % (y, s.encode()))

# 1. photo.pdf: RGB JPEG at 400 dpi
pdf = Pdf.new(); p = new_page(pdf)
im = photo(1600, 1200)
put_image(pdf, p, "/Im1", img_stream(pdf, jpeg_bytes(im, 95), 1600, 1200, Name.DeviceRGB, filt=Name.DCTDecode), (36, 300, 288*1.5, 216*1.5))
text(pdf, p, "Photo page")
pdf.save(f"{OUT}/photo.pdf")

# 2. screenshot.pdf: few colours, raw Flate (no predictor) RGB
pdf = Pdf.new(); p = new_page(pdf)
im = screenshot(1200, 800).quantize(colors=12).convert("RGB")
put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(im.tobytes(), 6), 1200, 800, Name.DeviceRGB, filt=Name.FlateDecode), (36, 300, 540, 360))
text(pdf, p, "Screenshot page")
pdf.save(f"{OUT}/screenshot.pdf")

# 3. fakegray.pdf: gray photo stored as RGB Flate
pdf = Pdf.new(); p = new_page(pdf)
im = photo(800, 600, "L").convert("RGB")
put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(im.tobytes(), 6), 800, 600, Name.DeviceRGB, filt=Name.FlateDecode), (36, 300, 400, 300))
pdf.save(f"{OUT}/fakegray.pdf")

# 4. scan.pdf: bilevel scan stored as 8-bit gray Flate at 300 dpi, two pages same image twice (dup objects)
pdf = Pdf.new()
im = scan_bilevel(2550, 3300)
for i in range(2):
    p = new_page(pdf)
    put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(im.tobytes(), 6), 2550, 3300, Name.DeviceGray, filt=Name.FlateDecode), (0, 0, 612, 792))
pdf.save(f"{OUT}/scan.pdf")

# 5. jpegscan.pdf: near-bilevel scan as gray JPEG at 300 dpi
pdf = Pdf.new(); p = new_page(pdf)
im2 = scan_bilevel(2550, 3300).filter(ImageFilter.GaussianBlur(0.6))
put_image(pdf, p, "/Im1", img_stream(pdf, jpeg_bytes(im2, 85), 2550, 3300, Name.DeviceGray, filt=Name.DCTDecode), (0, 0, 612, 792))
pdf.save(f"{OUT}/jpegscan.pdf")

# 6. cmyk.pdf: Adobe CMYK JPEG (Pillow writes inverted Adobe CMYK) with Decode [1 0 ...]
pdf = Pdf.new(); p = new_page(pdf)
im = photo(1200, 900).convert("CMYK")
put_image(pdf, p, "/Im1", img_stream(pdf, jpeg_bytes(im, 92), 1200, 900, Name.DeviceCMYK, filt=Name.DCTDecode, Decode=Array([1,0,1,0,1,0,1,0])), (36, 300, 360, 270))
pdf.save(f"{OUT}/cmyk.pdf")

# 7. alpha.pdf: RGB image with soft mask, both Flate
pdf = Pdf.new(); p = new_page(pdf)
im = photo(900, 900)
mask = Image.new("L", (900, 900), 0); ImageDraw.Draw(mask).ellipse([50, 50, 850, 850], fill=255); mask = mask.filter(ImageFilter.GaussianBlur(8))
sm = img_stream(pdf, zlib.compress(mask.tobytes()), 900, 900, Name.DeviceGray, filt=Name.FlateDecode)
put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(im.tobytes()), 900, 900, Name.DeviceRGB, filt=Name.FlateDecode, SMask=pdf.make_indirect(sm)), (36, 200, 300, 300))
pdf.save(f"{OUT}/alpha.pdf")

# 8. mask.pdf: stencil mask (ImageMask) 1-bit, uncompressed
pdf = Pdf.new(); p = new_page(pdf)
m = scan_bilevel(1700, 2200).convert("1")
s = Stream(pdf, m.tobytes()); s.Type = Name.XObject; s.Subtype = Name.Image; s.Width = 1700; s.Height = 2200; s.ImageMask = True
put_image(pdf, p, "/Im1", s, (0, 0, 612, 792), extra=b"0.2 0.4 0.8 rg ")
pdf.save(f"{OUT}/mask.pdf")

# 9. indexed.pdf: Indexed 8-bit image with 4 colours, Flate
pdf = Pdf.new(); p = new_page(pdf)
pal = bytes([255,255,255, 0,0,0, 200,0,0, 0,0,200])
idx = Image.new("P", (1000, 700), 0); d = ImageDraw.Draw(idx)
for i in range(0, 1000, 50): d.rectangle([i, 0, i+20, 700], fill=(i//50) % 4)
cs = Array([Name.Indexed, Name.DeviceRGB, 3, pikepdf.String(pal)])
put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(idx.tobytes()), 1000, 700, cs, filt=Name.FlateDecode), (36, 300, 500, 350))
pdf.save(f"{OUT}/indexed.pdf")

# 10. inline.pdf: a large-ish inline image (RGB, raw) + text
pdf = Pdf.new(); p = new_page(pdf)
im = photo(120, 90)
data = im.tobytes()
p.Contents = pdf.make_stream(b"q 300 0 0 225 50 400 cm BI /W 120 /H 90 /CS /RGB /BPC 8 ID " + data + b" EI Q\n")
pdf.save(f"{OUT}/inline.pdf")

# 11. form.pdf: image inside a form XObject with a scaling /Matrix, drawn on 2 pages
pdf = Pdf.new()
im = photo(1200, 1200)
img = pdf.make_indirect(img_stream(pdf, jpeg_bytes(im, 95), 1200, 1200, Name.DeviceRGB, filt=Name.DCTDecode))
form = Stream(pdf, b"q 100 0 0 100 0 0 cm /I Do Q")
form.Type = Name.XObject; form.Subtype = Name.Form; form.BBox = Array([0,0,100,100]); form.Matrix = Array([2,0,0,2,0,0])
form.Resources = Dictionary(XObject=Dictionary(I=img))
form = pdf.make_indirect(form)
for i in range(2):
    p = new_page(pdf)
    p.Resources.XObject.Fm = form
    p.Contents = pdf.make_stream(b"q 1 0 0 1 50 300 cm /Fm Do Q")
pdf.save(f"{OUT}/form.pdf")

# 12. deep16.pdf: 16-bit gray image
pdf = Pdf.new(); p = new_page(pdf)
w, h = 400, 300
import struct
raw = bytearray()
for y in range(h):
    for x in range(w):
        raw += struct.pack(">H", (x * 65535 // w + y * 13) & 0xFFFF)
put_image(pdf, p, "/Im1", img_stream(pdf, zlib.compress(bytes(raw)), w, h, Name.DeviceGray, bpc=16, filt=Name.FlateDecode), (36, 300, 400, 300))
pdf.save(f"{OUT}/deep16.pdf")

# 13. encrypted.pdf: AES-256 user password "pw" with a photo
pdf = Pdf.open(f"{OUT}/photo.pdf")
pdf.docinfo["/Title"] = "Secret"
pdf.save(f"{OUT}/encrypted.pdf", encryption=pikepdf.Encryption(user="pw", owner="ownerpw", R=6))

# 14. junk.pdf: metadata, thumbnails, PieceInfo, JS, attachment, outline, annotation
pdf = Pdf.open(f"{OUT}/screenshot.pdf")
pdf.docinfo["/Title"] = "Junk"
with pdf.open_metadata() as meta: meta["dc:title"] = "Junk"
p = pdf.pages[0]
p.obj.PieceInfo = Dictionary(Illustrator=Dictionary(Private=pdf.make_stream(os.urandom(50000)), LastModified=pikepdf.String("D:2020")))
p.obj.Thumb = img_stream(pdf, zlib.compress(os.urandom(3000)), 50, 20, Name.DeviceRGB, filt=Name.FlateDecode)
pdf.Root.OpenAction = Dictionary(S=Name.JavaScript, JS=pikepdf.String("app.alert('hi')"))
pdf.attachments["data.bin"] = pikepdf.AttachedFileSpec(pdf, os.urandom(20000), mime_type="application/octet-stream")
with pdf.open_outline() as outline: outline.root.append(pikepdf.OutlineItem("Start", 0))
p.Annots = pdf.make_indirect(Array([pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=Array([10,10,30,30]), Contents=pikepdf.String("note")))]))
pdf.save(f"{OUT}/junk.pdf")
# 15. bigphoto.pdf: a 12-megapixel JPEG photo filling a page (~350 dpi)
pdf = Pdf.new(); p = new_page(pdf)
w, h = 3000, 4000
base = Image.effect_noise((300, 400), 60)
img = Image.merge("RGB", [base, base.transpose(Image.FLIP_TOP_BOTTOM), base.transpose(Image.FLIP_LEFT_RIGHT)])
img = img.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(2))
img = Image.blend(img, Image.effect_noise((w, h), 20).convert("RGB"), 0.15)
put_image(pdf, p, "/Im1", img_stream(pdf, jpeg_bytes(img, 92), w, h, Name.DeviceRGB, filt=Name.DCTDecode), (0, 0, 612, 792))
pdf.save(f"{OUT}/bigphoto.pdf")
print("corpus written to", OUT)
