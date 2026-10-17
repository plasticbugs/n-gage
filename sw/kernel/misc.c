/* The small services: characters, time, locale, HAL, and the screen. */
#include "kobj.h"
#include "mm.h"

/* ---- characters (Latin-1; enough for the firmware's own strings) -------- */
static int lower(int c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE && c != 0xD7)) return c + 32;
    return c;
}

static int upper(int c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 0xE0 && c <= 0xFE && c != 0xF7)) return c - 32;
    return c;
}

static int category(int c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE && c != 0xD7)) return 0x00;    /* Lu */
    if ((c >= 'a' && c <= 'z') || (c >= 0xDF && c <= 0xFF && c != 0xF7)) return 0x01;    /* Ll */
    if (c >= '0' && c <= '9') return 0x40;                                                  /* Nd */
    if (c == ' ' || c == 0xA0) return 0x70;                                                 /* Zs */
    if (c < 0x20 || (c >= 0x7F && c < 0xA0)) return 0x80;                                  /* Cc */
    if (c == '+' || c == '<' || c == '=' || c == '>' || c == '|' || c == '~' || c == 0xAC || c == 0xB1 || c == 0xD7 || c == 0xF7) return 0x60;
    if (c == '$' || (c >= 0xA2 && c <= 0xA5)) return 0x61;                                  /* Sc */
    if (c == '^' || c == '`' || c == 0xA8 || c == 0xAF || c == 0xB4 || c == 0xB8) return 0x62;
    if (c == '_') return 0x50;
    if (c == '-') return 0x51;
    if (c == '(' || c == '[' || c == '{') return 0x52;
    if (c == ')' || c == ']' || c == '}') return 0x53;
    if (c < 0x80) return 0x56;                                                             /* Po */
    if (c >= 0x100) return 0x10;                                                           /* Lo */
    return 0x63;                                                                           /* So */
}

s32 unicode_exec(int idx, u32 a0)
{
    int c = (int)(a0 & 0xFFFF);
    switch (idx) {
    case 0x4F: return lower(c);       /* Fold: case and nothing else here */
    case 0x50: return lower(c);       /* Collate                          */
    case 0x51: return lower(c);
    case 0x52: return upper(c);
    case 0x53: return category(c);
    }
    return c;
}

/* ---- time ------------------------------------------------------------------
 * TTime counts microseconds from 0 AD.  The clock starts at a fixed date so
 * runs repeat exactly: 2004-01-01 00:00, the year of these games. */
#define Y2004_US 63208512000000000ULL     /* 0 AD to 2004-01-01, in us */
u64 home_time_us(void) { return Y2004_US + now_us(); }

/* TLocale, filled in English defaults.  (Its layout, Symbian 6.1:
 * iCountryCode, iUniversalTimeOffset, iDateFormat, iTimeFormat,
 * iCurrencySymbolPosition, iCurrencySpaceBetween, iCurrencyDecimalPlaces,
 * iCurrencyNegativeInBrackets, iCurrencyTriadsAllowed, iThousandsSeparator,
 * iDecimalSeparator, iDateSeparator[4], iTimeSeparator[4], iAmPmSymbolPosition,
 * iAmPmSpaceBetween, iDaylightSaving, iHomeDaylightSavingZone, iWorkDays,
 * iStartOfWeek, iClockFormat, iUnitsGeneral, iUnitsDistanceShort,
 * iUnitsDistanceLong, iExtraNegativeCurrencyFormatFlags ...) */
static u32 locale[] = {
    44,            /* iCountryCode: UK                 */
    0,             /* iUniversalTimeOffset             */
    1,             /* iDateFormat: EDateEuropean        */
    0,             /* iTimeFormat: ETime12              */
    0,             /* iCurrencySymbolPosition: leading */
    0,             /* iCurrencySpaceBetween            */
    2,             /* iCurrencyDecimalPlaces           */
    0,             /* iCurrencyNegativeInBrackets      */
    1,             /* iCurrencyTriadsAllowed           */
    ',',           /* iThousandsSeparator              */
    '.',           /* iDecimalSeparator                */
    0, '/', '/', 0,/* iDateSeparator[4]                */
    0, ':', ':', 0,/* iTimeSeparator[4]                */
    1,             /* iAmPmSymbolPosition: trailing     */
    1,             /* iAmPmSpaceBetween                */
    0,             /* iDaylightSaving                  */
    2,             /* iHomeDaylightSavingZone: Home    */
    0x1F,          /* iWorkDays                        */
    0,             /* iStartOfWeek: Monday             */
    0,             /* iClockFormat: analog             */
    1,             /* iUnitsGeneral: metric            */
    1, 1,          /* iUnitsDistanceShort/Long         */
    0,             /* iExtraNegativeCurrencyFormatFlags*/
};

/* exec 0x68: TLocale::Refresh */
void locale_refresh(u32 p)
{
    for (unsigned i = 0; i < sizeof locale / sizeof locale[0]; i++) uwrite32(p + 4 * i, locale[i]);
}

/* exec 0xC00069: TLocale::Set, from the locale the system chose */
void locale_set(u32 p)
{
    for (unsigned i = 0; i < sizeof locale / sizeof locale[0]; i++) locale[i] = uread32(p + 4 * i);
}

/* ---- HAL ------------------------------------------------------------------- */
/* UserHal's functions (EKA1 numbering, from EUser's UserHal::* stubs).
 * The info classes go in TPckgBufs; the rest write one TInt. */
/* Exec 0x8000AB: the locale's TCharSet { char data set, collation data set }.
 * No character data, and one collation method with no tables, so EUser
 * collates by its own standard order (as EKA2L1 does).  In user-readable
 * memory: EUser reads it in place. */
u32 locale_charset(void)
{
    static u32 cs;
    if (cs) return cs;
    u32 b = vm_reserve(NGVM_PAGE_SIZE);
    if (!b || vm_commit(b, NGVM_PAGE_SIZE)) kpanic("no memory for the char set");
    u32 *w = (u32 *)b;
    memset(w, 0, 64);
    w[0] = 0;               w[1] = b + 8;       /* TCharSet                    */
    w[2] = b + 16;          w[3] = 1;           /* TCollationDataSet: 1 method */
    w[4] = 0; w[5] = 0; w[6] = 0; w[7] = 0;     /* TCollationMethod: id, main,
                                                   override, flags            */
    return cs = b;
}

/* An info package into a caller's buffer, as Kern::InfoCopy: as much as
 * fits, so a V1 buffer gets the V1 part of a V2 answer. */
static s32 info_copy(u32 d, const u8 *p, int n)
{
    int m = des_maxlen(d);
    return des_write8(d, p, n < m ? n : m);
}

/* HAL.dll's EDisplayContrast: functions 27 (set) and 28 (get).  The LCD has
 * no contrast to set; the value is only kept. */
static s32 contrast = 8;

s32 hal_get(u32 fn, u32 a1, u32 a2)
{
    extern u32 mm_free_bytes(void);
    if (kflags & DBGF_EXEC) kprintf("[hal] get %d (%x %x)\n", fn, a1, a2);
    switch (fn) {
    case 0: {                                   /* MachineInfo: TMachineInfoV2  */
        static const u32 w[] = {
            0x00000106,                         /* iRomVersion 6.1 build 0      */
            0,                                  /* iXYInputType: none           */
            1, 1,                               /* keyboard, backlight          */
            LCD_W, LCD_H,                       /* iDisplaySizeInPixels         */
            0, 0,                               /* iXYInputSizeInPixels         */
            2400, 2800,                         /* iPhysicalScreenSize (twips)  */
            0, 0,                               /* iOffsetToDisplayInPixels     */
            0, 0,                               /* keyboard, display ids        */
            0x4E474147, 0x45000001,             /* iMachineUniqueId             */
            0,                                  /* iLedCapabilities             */
            104000, 100,                        /* clock kHz, speed factor      */
            4096,                               /* iMaximumDisplayColors        */
            1, 0,                               /* V2: language, keyboard index */
        };
        return info_copy(a1, (const u8 *)w, sizeof w);
    }
    case 1: {                                   /* MemoryInfo: TMemoryInfoV1    */
        u32 w[6] = { NGVM_RAM_SIZE, IO(IO_ROM_SIZE), mm_free_bytes(), mm_free_bytes(), 0, 0 };
        return info_copy(a1, (const u8 *)w, sizeof w);
    }
    case 2: {                                   /* DriveInfo: TDriveInfoV1      */
        /* local drive 0: the internal flash (C:); 1: the RAM drive (D:);
         * 2: the card (E:), which holds the game */
        static const char *const drv[] = { "IntDrive", "RamDrive", "MultiMediaCard0" };
        static u8 b[4 + 9 * 40 + 4 + 4 * 40 + 4];
        memset(b, 0, sizeof b);
        u32 *w = (u32 *)b;
        w[0] = 3;
        for (int i = 0; i < 9; i++) {
            u32 *t = (u32 *)(b + 4 + 40 * i);
            t[0] = 3u << 28; t[1] = 16;          /* TBuf<16>              */
            if (i < 3) {
                int n = 0;
                while (drv[i][n]) { ((u16 *)(t + 2))[n] = (u8)drv[i][n]; n++; }
                t[0] |= n;
            }
        }
        *(u32 *)(b + 4 + 9 * 40) = 1;            /* iTotalSockets          */
        for (int i = 0; i < 4; i++) {
            u32 *t = (u32 *)(b + 8 + 9 * 40 + 40 * i);
            t[0] = 3u << 28; t[1] = 16;
            if (i == 0) {
                int n = 0;
                while (drv[2][n]) { ((u16 *)(t + 2))[n] = (u8)drv[2][n]; n++; }
                t[0] |= n;
            }
        }
        return info_copy(a1, b, sizeof b);
    }
    case 4: uwrite32(a1, 0); return KErrNone;   /* StartupReason: cold          */
    case 5: uwrite32(a1, 0); return KErrNone;   /* FaultReason                  */
    case 8: uwrite32(a1, NGVM_PAGE_SIZE); return KErrNone;
    case 10: uwrite32(a1, 15625); return KErrNone;  /* TickPeriod: 64 Hz        */
    case 27: contrast = (s32)uread32(a1); return KErrNone;  /* SetDisplayContrast  */
    case 28: uwrite32(a1, (u32)contrast); return KErrNone;  /* DisplayContrast     */
    }
    kpanic("HAL function %d unimplemented (%x %x)", fn, a1, a2);
}

/* ---- the screen -------------------------------------------------------------
 * EColor4K, 176 x 208, 16 bits a pixel, preceded by the 32-byte palette
 * header EKA1 Nokia drivers put there; the LCD scans from +0x20. */
#define LCD_HDR 0x20
static u32 lcd_mem;

u32 lcd_buffer(void)
{
    if (!lcd_mem) {
        extern u32 vm_reserve(u32);
        extern int vm_commit(u32, u32);
        u32 size = LCD_HDR + LCD_W * LCD_H * 2;
        lcd_mem = vm_reserve(size);
        if (!lcd_mem || vm_commit(lcd_mem, size)) kpanic("no memory for the screen");
        IO(IO_LCD_BASE) = lcd_mem + LCD_HDR;
        IO(IO_LCD_CTRL) = 1;
    }
    return lcd_mem;
}

/* ---- the loader's calls, until they are understood --------------------------- */
void loader_info_dump(u32 li)
{
    static const char *const f[] = { "uid1", "uid2", "uid3", "check", "cksumcode", "codesize", "datasize",
        "heapmin", "heapmax", "stack", "bss", "entry", "dllref", "dllrefcount", "expdir", "expcount",
        "tgtcode", "tgtcodebase", "tgtdata", "tgtdatabase" };
    for (int i = 0; i < 20; i++) kprintf("  %s %08x\n", f[i], uread32(li + 4 * i));
    for (int k = 0; k < 3; k++) {
        u32 d = li + 0x50 + 0x208 * k;
        kprintf("  %s ", k == 0 ? "filename" : k == 1 ? "rootname" : "path");
        kputs16((const u16 *)(d + 8), uread32(d) & 0xFFFF);
        kprintf("\n");
    }
    static const char *const g[] = { "fromram", "isdll", "already", "handle", "thread", "process",
        "library", "handlemask", "priority", "textsize", "libptr" };
    for (int i = 0; i < 11; i++) kprintf("  %s %08x\n", g[i], uread32(li + 0x668 + 4 * i));
}

/* ---- DLL global data --------------------------------------------------------
 * ROM DLLs have no writable statics; the few that need state keep it here,
 * in a block the kernel holds per DLL (keyed by its entry point). */
#define MAX_DLLG 32
static struct { u32 handle, size; u8 *data; } dllg[MAX_DLLG];

static int dllg_find(u32 h)
{
    for (int i = 0; i < MAX_DLLG; i++) if (dllg[i].data && dllg[i].handle == h) return i;
    return -1;
}

s32 dll_global_alloc(u32 h, u32 size)
{
    if (dllg_find(h) >= 0) return KErrNone;
    for (int i = 0; i < MAX_DLLG; i++)
        if (!dllg[i].data) {
            dllg[i].handle = h;
            dllg[i].size = size;
            dllg[i].data = kzalloc(size ? size : 4);
            return KErrNone;
        }
    return KErrNoMemory;
}

s32 dll_global_exec(int idx, u32 a0, u32 a1, u32 a2, u32 a3)
{
    int i = dllg_find(a0);
    if (idx == 0x7D) return i >= 0;
    if (i < 0) return KErrNotReady;
    if ((s32)a1 < 0) return KErrArgument;
    if (idx == 0x7E) {                          /* read(h, pos, size, TDes8&) */
        s32 n = (s32)a2;
        if (n < 0) return KErrArgument;
        if ((u32)n > dllg[i].size - a1) n = dllg[i].size - a1;
        if (n > des_maxlen(a3)) n = des_maxlen(a3);
        return des_write8(a3, dllg[i].data + a1, n);
    }
    /* write(h, pos, const TDesC8&) */
    int n = des_len(a2);
    if (a1 + n > dllg[i].size) return KErrNoMemory;
    ucopy_from(dllg[i].data + a1, des_ptr(a2), n);
    return KErrNone;
}

/* ---- the locale's words: execs 0x800061-0x800067 ---------------------------
 * T*Name::Set(index) asks the kernel for the text into the TBuf it is; the
 * currency symbol takes no index.  English, as the rest of the locale. */
static const char *const days[7] = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
static const char *const months[12] = { "January", "February", "March", "April", "May", "June", "July",
                                        "August", "September", "October", "November", "December" };

static s32 put_text(u32 d, const char *s, int n)
{
    u16 b[32];
    int k = 0;
    while (s[k] && k < n && k < 32) { b[k] = (u8)s[k]; k++; }
    return des_write16(d, b, k);
}

s32 locale_text(int idx, u32 a0, u32 a1)
{
    int i = (int)a0;
    switch (idx) {
    case 0x61: return i >= 0 && i < 7 ? put_text(a1, days[i], 32) : KErrArgument;
    case 0x62: return i >= 0 && i < 7 ? put_text(a1, days[i], 3) : KErrArgument;
    case 0x63: return i >= 0 && i < 12 ? put_text(a1, months[i], 32) : KErrArgument;
    case 0x64: return i >= 0 && i < 12 ? put_text(a1, months[i], 3) : KErrArgument;
    case 0x65: {                                /* day of month, from 0: 1st, 2nd ... */
        int d = i + 1;
        const char *s = (d % 10 == 1 && d != 11) ? "st" : (d % 10 == 2 && d != 12) ? "nd"
                      : (d % 10 == 3 && d != 13) ? "rd" : "th";
        return i >= 0 && i < 31 ? put_text(a1, s, 2) : KErrArgument;
    }
    case 0x66: return i == 0 || i == 1 ? put_text(a1, i ? "pm" : "am", 2) : KErrArgument;
    case 0x67: { u16 pound = 0xA3; return des_write16(a0, &pound, 1); }
    }
    return KErrNotSupported;
}
