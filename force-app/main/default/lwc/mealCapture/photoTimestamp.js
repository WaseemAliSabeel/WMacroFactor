// Reads when a photo was taken, so mealCapture can default "Logged Date & Time" to the
// capture time instead of "now". Must run on the ORIGINAL File: the canvas re-encode in
// mealCapture strips EXIF.
//
// Source order (best first):
//   1. EXIF DateTimeOriginal / DateTimeDigitized / DateTime (JPEG), using the EXIF
//      OffsetTime tag when the camera wrote one, otherwise the device's local timezone
//   2. File.lastModified — browsers expose no real "created" time; for camera captures this is
//      the capture time, for gallery copies it may be a save/download time
//
// Returns { date: Date, source: 'exif' | 'file' } or null when nothing trustworthy is found.

const EXIF_HEAD_BYTES = 256 * 1024; // the EXIF APP1 segment sits at the start of a JPEG (max 64 KB)
const MIN_YEAR = 2000;              // rejects zeroed / epoch placeholder dates

const TAG_DATETIME          = 0x0132;
const TAG_EXIF_IFD          = 0x8769;
const TAG_DATETIME_ORIGINAL = 0x9003;
const TAG_DATETIME_DIGITIZED = 0x9004;
const TAG_OFFSET_ORIGINAL   = 0x9011;
const TAG_OFFSET_DIGITIZED  = 0x9012;
const TAG_OFFSET_TIME       = 0x9010;

// Reads the first bytes of the file as an ArrayBuffer.
function readHead(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload  = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsArrayBuffer(file.slice(0, EXIF_HEAD_BYTES));
    });
}

// Reads an ASCII tag value. Values of 4 bytes or fewer are stored inline in the IFD entry;
// longer ones are stored at an offset from the TIFF header.
function readAscii(view, tiff, entry, little) {
    const count = view.getUint32(entry + 4, little);
    const start = count <= 4 ? entry + 8 : tiff + view.getUint32(entry + 8, little);
    let s = '';
    for (let i = 0; i < count; i++) {
        const c = view.getUint8(start + i);
        if (c === 0) break;
        s += String.fromCharCode(c);
    }
    return s;
}

// Collects the ASCII tags we care about from one IFD into a { tag: string } map.
function readIfdAscii(view, tiff, ifdOffset, little, wanted) {
    const found = {};
    let exifIfd = null;
    const base = tiff + ifdOffset;
    const n = view.getUint16(base, little);
    for (let i = 0; i < n; i++) {
        const entry = base + 2 + i * 12;
        const tag = view.getUint16(entry, little);
        if (tag === TAG_EXIF_IFD) exifIfd = view.getUint32(entry + 8, little);
        else if (wanted.includes(tag)) found[tag] = readAscii(view, tiff, entry, little);
    }
    return { found, exifIfd };
}

// Walks the JPEG segments to the EXIF APP1 and returns the best capture-time candidate
// as { text: 'YYYY:MM:DD HH:MM:SS', offset: '+05:30' | null }, or null if there is none.
function readExifDateText(buffer) {
    const view = new DataView(buffer);
    if (view.byteLength < 12 || view.getUint16(0) !== 0xFFD8) return null; // not a JPEG

    let pos = 2;
    while (pos + 4 <= view.byteLength) {
        if (view.getUint8(pos) !== 0xFF) return null;
        const marker = view.getUint8(pos + 1);
        if (marker === 0xDA) return null; // start of image data — no EXIF found
        const size = view.getUint16(pos + 2);
        const isExif = marker === 0xE1
            && view.getUint32(pos + 4) === 0x45786966 // "Exif"
            && view.getUint16(pos + 8) === 0;
        if (isExif) {
            const tiff = pos + 10;
            const little = view.getUint16(tiff) === 0x4949; // "II" little-endian, "MM" big-endian
            if (view.getUint16(tiff + 2, little) !== 42) return null;

            const ifd0 = readIfdAscii(view, tiff, view.getUint32(tiff + 4, little), little, [TAG_DATETIME]);
            let exif = { found: {} };
            if (ifd0.exifIfd) {
                exif = readIfdAscii(view, tiff, ifd0.exifIfd, little, [
                    TAG_DATETIME_ORIGINAL, TAG_DATETIME_DIGITIZED,
                    TAG_OFFSET_ORIGINAL, TAG_OFFSET_DIGITIZED, TAG_OFFSET_TIME
                ]);
            }
            const e = exif.found;
            if (e[TAG_DATETIME_ORIGINAL]) return { text: e[TAG_DATETIME_ORIGINAL], offset: e[TAG_OFFSET_ORIGINAL] || e[TAG_OFFSET_TIME] || null };
            if (e[TAG_DATETIME_DIGITIZED]) return { text: e[TAG_DATETIME_DIGITIZED], offset: e[TAG_OFFSET_DIGITIZED] || e[TAG_OFFSET_TIME] || null };
            if (ifd0.found[TAG_DATETIME]) return { text: ifd0.found[TAG_DATETIME], offset: e[TAG_OFFSET_TIME] || null };
            return null;
        }
        pos += 2 + size;
    }
    return null;
}

// Converts EXIF "YYYY:MM:DD HH:MM:SS" (+ optional "+HH:MM" offset) to a Date. EXIF has no
// timezone of its own, so without an offset tag the time is read as the device's local time.
export function parseExifDate(text, offset) {
    const m = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(text || '');
    if (!m) return null;
    const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
    const off = /^([+-])(\d{2}):(\d{2})$/.exec(offset || '');
    const date = off
        ? new Date(Date.UTC(y, mo - 1, d, h, mi, s) - (off[1] === '-' ? -1 : 1) * (Number(off[2]) * 60 + Number(off[3])) * 60000)
        : new Date(y, mo - 1, d, h, mi, s);
    return isNaN(date.getTime()) || date.getFullYear() < MIN_YEAR ? null : date;
}

export async function readPhotoTimestamp(file) {
    try {
        const exif = readExifDateText(await readHead(file));
        const date = exif && parseExifDate(exif.text, exif.offset);
        if (date) return { date, source: 'exif' };
    } catch (e) {
        // Truncated / non-standard EXIF — fall through to the file date.
    }
    if (file.lastModified) {
        const date = new Date(file.lastModified);
        if (!isNaN(date.getTime()) && date.getFullYear() >= MIN_YEAR) return { date, source: 'file' };
    }
    return null;
}