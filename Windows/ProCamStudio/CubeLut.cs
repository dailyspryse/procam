using System;
using System.Globalization;

namespace ProCam;

/// Validates a .cube file before it is sent to the phone (which parses it
/// again with Shared/CubeLUT.swift). Mirrors that parser's rules.
public static class CubeLut
{
    public static void Validate(string text)
    {
        int size = 0, count = 0, lineNo = 0;
        foreach (var raw in text.Split('\n'))
        {
            lineNo++;
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            switch (parts[0])
            {
                case "TITLE": case "DOMAIN_MIN": case "DOMAIN_MAX":
                case "LUT_3D_INPUT_RANGE": case "LUT_1D_INPUT_RANGE":
                    continue;
                case "LUT_3D_SIZE":
                    size = parts.Length > 1 && int.TryParse(parts[1], out var s) ? s : 0;
                    continue;
                case "LUT_1D_SIZE":
                    throw new FormatException("1D-LUTs werden nicht unterstützt");
            }
            if (parts.Length >= 3
                && float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out _)
                && float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out _)
                && float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out _))
            {
                count++;
            }
            else if (!char.IsLetter(parts[0][0]))
            {
                throw new FormatException($"Zeile {lineNo} ist ungültig");
            }
        }
        if (size < 2) throw new FormatException("LUT_3D_SIZE fehlt");
        if (count != size * size * size)
            throw new FormatException($"Erwartet {size * size * size} Einträge, gefunden {count}");
    }
}
