#!/bin/sh
# Validate a single lowercase-hex UTF-8 SSID on stdin; never decode into shell.
# Output is canonical hex plus LF. Empty input is not a custom name.
[ "$#" = 0 ] || exit 64
LC_ALL=C awk '
    BEGIN { digits = "0123456789abcdef" }
    {
        if (NR != 1 || length($0) < 2 || length($0) > 64 ||
            length($0) % 2 || $0 ~ /[^0-9a-f]/) { bad=1; exit }
        hex=$0
        n=length(hex)/2
        for (i=1; i<=n; i++) {
            high=index(digits, substr(hex, 2*i-1, 1))-1
            b[i]=high*16+index(digits, substr(hex, 2*i, 1))-1
        }
        for (i=1; i<=n; i++) {
            c=b[i]
            if (c < 128) { cp=c; more=0; min=0 }
            else if (c >= 194 && c <= 223) { cp=c-192; more=1; min=128 }
            else if (c >= 224 && c <= 239) { cp=c-224; more=2; min=2048 }
            else if (c >= 240 && c <= 244) { cp=c-240; more=3; min=65536 }
            else { bad=1; exit }
            if (i+more > n) { bad=1; exit }
            for (j=0; j<more; j++) {
                c=b[++i]
                if (c < 128 || c > 191) { bad=1; exit }
                cp=cp*64+c-128
            }
            # Reject overlong UTF-8, surrogates, out-of-range code points,
            # Unicode Cc controls (including NUL, CR, LF and DEL), and
            # Unicode line/paragraph separators, matching the console.
            if (cp < min || cp > 1114111 || (cp >= 55296 && cp <= 57343) ||
                cp < 32 || (cp >= 127 && cp <= 159) || cp == 8232 || cp == 8233) { bad=1; exit }
        }
    }
    END { if (bad || NR != 1) exit 65; print hex }
'
