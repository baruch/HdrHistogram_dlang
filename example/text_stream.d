module main;

import hdrhistogram;
import std.stdio;

int main() {
    HdrHistogram!(long, 1, 30_000_000, 2) hdr;

    hdr.open();

    long val;
    while (!stdin.eof()) {
        stdin.readf!"%d"(val);
        hdr.put(val);
    }

    foreach (percentile; [ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 95.0, 99.0, 99.9, 99.99 ]) {
        writefln("percentile %f value %d ", percentile, hdr.valueAtPercentile(percentile));
    }

    return 0;
}
