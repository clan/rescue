function check(k)
{
    if (NF != format[k]["nf"]) {
        print "0 malformed line:", $0
    } else {
        print format[k]["n"], $0
    }
}

BEGIN {
    format["dir"]["n"] = 1
    format["dir"]["nf"] = 5
    format["nod"]["n"] = 2
    format["nod"]["nf"] = 8
    format["file"]["n"] = 2
    format["file"]["nf"] = 6
    format["slink"]["n"] = 3
    format["slink"]["nf"] = 6
}

{
    if (NF == 0 || $1 ~ /^#/) {
        next
    }
    if ($0 ~ /^dir\s+\//) {
        check("dir")
    } else if ($0 ~ /^nod\s+\//) {
        check("nod")
    } else if ($0 ~ /^file\s+\//) {
        check("file")
    } else if ($0 ~ /^slink\s+\//) {
        check("slink")
    } else {
        print "0 malformed line:", $0
    }
}
