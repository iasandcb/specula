package com.ias.specula

/** Swift PhysicalKey's US ANSI HID map. Apple expects Meta for Option and Super for Command. */
object PhysicalKey {
    fun symbol(hid: Int, shift: Boolean = false, option: Boolean = false): Int? {
        if (option && hid == 47) return if (shift) 0x0100201d else 0x0100201c
        if (option && hid == 48) return if (shift) 0x01002019 else 0x01002018
        if (hid in 4..29) return (if (shift) 65 else 97) + hid - 4
        if (shift && hid in 30..39) return "!@#$%^&*()"[hid - 30].code
        if (hid in 30..38) return 49 + hid - 30
        if (shift)
            mapOf(
                    45 to 95,
                    46 to 43,
                    47 to 123,
                    48 to 125,
                    49 to 124,
                    51 to 58,
                    52 to 34,
                    53 to 126,
                    54 to 60,
                    55 to 62,
                    56 to 63,
                )[hid]
                ?.let {
                    return it
                }
        return mapOf(
            39 to 48,
            40 to 0xff0d,
            41 to 0xff1b,
            42 to 0xff08,
            43 to 0xff09,
            44 to 32,
            45 to 45,
            46 to 61,
            47 to 91,
            48 to 93,
            49 to 92,
            51 to 59,
            52 to 39,
            53 to 96,
            54 to 44,
            55 to 46,
            56 to 47,
            57 to 0xffe5,
            76 to 0xffff,
            79 to 0xff53,
            80 to 0xff51,
            81 to 0xff54,
            82 to 0xff52,
            224 to 0xffe3,
            225 to 0xffe1,
            226 to 0xffeb,
            227 to 0xffeb,
            228 to 0xffe4,
            229 to 0xffe2,
            230 to 0xffe7,
            231 to 0xffec,
        )[hid]
    }
}
