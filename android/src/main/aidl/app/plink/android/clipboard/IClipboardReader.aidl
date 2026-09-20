package app.plink.android.clipboard;

import android.os.Bundle;

interface IClipboardReader {
    Bundle readClipboard() = 1;
    void destroy() = 16777114;
}
