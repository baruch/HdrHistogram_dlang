module hdrhistogram;

struct HdrHistogram(T, T lowestTrackableValue, T highestTrackableValue, int significantFigures) {
    import std.math: pow, ceil, log, floor;

    static assert( lowestTrackableValue >= 1 );
    static assert( significantFigures >= 1 );
    static assert( significantFigures <= 5 );
    static assert( lowestTrackableValue * 2 <= highestTrackableValue );

    enum long largestValueWithSingleUnitResolution = 2 * pow(10, significantFigures);
    enum int subBucketCountMagnitude = cast(int)ceil(log(largestValueWithSingleUnitResolution) / log(2));
    enum int subBucketHalfCountMagnitutde = cast(int)(subBucketCountMagnitude > 1 ? subBucketCountMagnitude-1 : 0);
    enum int unitMagnitude = cast(int)floor(log(lowestTrackableValue) / log(2));
    static assert( unitMagnitude + subBucketHalfCountMagnitutde <= 61);

    enum int subBucketCount = cast(int)pow(2, subBucketHalfCountMagnitutde + 1);
    enum int subBucketHalfCount = subBucketCount / 2;
    enum long subBucketMask = (cast(long)subBucketCount - 1) << unitMagnitude;

    enum bucketCount = bucketsNeededToCoverValue(highestTrackableValue);
    enum countsLen = (bucketCount + 1) * (subBucketCount / 2);

    void printConfig() {
        import std.stdio;

        writefln("Type: %s lowest: %d highest: %d significant: %d", T.stringof, lowestTrackableValue, highestTrackableValue, significantFigures);
        writefln("largestValueWithSingleUnitResolution: %d", largestValueWithSingleUnitResolution);
        writefln("subBucketCountMagnitude: %d", subBucketCountMagnitude);
        writefln("subBucketHalfCountMagnitutde: %d", subBucketHalfCountMagnitutde);
        writefln("unitMagnitude: %d", unitMagnitude);
        writefln("subBucketCount: %d", subBucketCount);
        writefln("subBucketHalfCount: %d", subBucketHalfCount);
        writefln("subBucketMask: %d", subBucketMask);
        writefln("bucketCount: %d", bucketCount);
        writefln("countsLen: %d", countsLen);
        writefln("count Size: %d", countsLen * long.sizeof);
        writefln("this size: %d", this.sizeof);
    }

    enum initialMaxValue = T.init;
    enum initialMinValue = T.max;

    long totalCount;
    T minValue;
    T maxValue;
    long[countsLen] counts;

    void open() {
        reset();
    }

    void close() {
    }

    void reset() {
        totalCount = 0;
        minValue = initialMinValue;
        maxValue = initialMaxValue;
        counts = counts.init;
    }

    void put(T value) {
        putValues(value, 1);
    }

    void putValues(T value, int count) {
        assert(value >= lowestTrackableValue);

        int countsIdx = indexFor(value);
        assert(countsIdx >= 0);
        assert(countsIdx < countsLen);

        countsIncNormalized(countsIdx, count);
        updateMinMax(value);
    }

    @property T min() {
        if (minValue == initialMinValue) {
            return initialMinValue;
        }

        return minValue;
    }

    @property T max() {
        if (maxValue == initialMaxValue) {
            return initialMaxValue;
        }

        return highestEquivalentValue(maxValue);
    }

    T valueAtPercentile(double percentile) {
        double requestedPercentile = percentile < 100.0 ? percentile : 100.0;

        long countAtPercentile = cast(long)(((requestedPercentile / 100.0) * totalCount) + 0.5);
        if (countAtPercentile < 1) {
            countAtPercentile = 1;
        }

        long cumulativeCount = 0;

        foreach (idx, count; getCountsIterator()) {
            cumulativeCount += count;
            if (cumulativeCount >= countAtPercentile) {
                T value = valueAtIndex(idx);
                return highestEquivalentValue(value);
            }
        }

        return 0;
    }

    @property double mean() {
        long weightedSum;

        foreach (idx, count; getCountsIterator()) {
            weightedSum += count * medianEquivalentValue(valueAtIndex(idx));
        }

        return (cast(double)weightedSum) / cast(double)totalCount;
    }

    double stddev(double mean) {
        double geometricMeanTotal = 0.0;

        foreach (idx, count; getCountsIterator()) {
            double dev = (cast(double)medianEquivalentValue(valueAtIndex(idx))) - mean;
            geometricMeanTotal += (dev*dev)*count;
        }

        import std.math: sqrt;
        return sqrt(geometricMeanTotal / cast(double)totalCount);
    }

    private static int bucketsNeededToCoverValue(T value) {
        long smallestUntrackableValue = subBucketCount << unitMagnitude;
        int bucketsNeeded = 1;

        while (smallestUntrackableValue <= value)
        {
            if (smallestUntrackableValue > T.max / 2)
            {
                return bucketsNeeded + 1;
            }
            smallestUntrackableValue *= 2;
            bucketsNeeded++;
        }

        return bucketsNeeded;
    }

    private void countsIncNormalized(int index, long count) @nogc {
        int normalizedIndex = normalizeIndex(index);
        counts[normalizedIndex] += count;
        totalCount += count;
    }

    private int normalizeIndex(int index) pure @nogc const {
        // TODO: We don't actually have the logic for the normalization, not really sure what it is for
        return index;
    }

    private void updateMinMax(T value) {
        if (value < minValue) {
            minValue = value;
        }
        if (value > maxValue) {
            maxValue = value;
        }
    }

    private int indexFor(T value) const {
        int bucketIndex = getBucketIndex(value);
        int subBucketIndex = getSubBucketIndex(value, bucketIndex);

        return countsIndex(bucketIndex, subBucketIndex);
    }

    private int countsIndex(int bucketIndex, int subBucketIndex) const {
        /* Calculate the index for the first entry in the bucket: */
        /* (The following is the equivalent of ((bucket_index + 1) * subBucketHalfCount) ): */
        int bucketBaseIndex = (bucketIndex + 1) << subBucketHalfCountMagnitutde;
        /* Calculate the offset in the bucket: */
        int offsetInBucket = subBucketIndex - subBucketHalfCount;
        /* The following is the equivalent of ((sub_bucket_index  - subBucketHalfCount) + bucketBaseIndex; */
        return bucketBaseIndex + offsetInBucket;
    }

    private int getBucketIndex(T value) const {
        import ldc.intrinsics: llvm_ctlz;
        int pow2ceiling = 64 - cast (int) llvm_ctlz(value | subBucketMask, true); // Smallest power of 2 containing value
        return pow2ceiling - unitMagnitude - (subBucketHalfCountMagnitutde + 1);
    }

    private int getSubBucketIndex(T value, int bucketIndex) const {
        return cast(int)(value >> (bucketIndex + unitMagnitude));
    }

    long sizeOfEquivalentValueRange(T value) const {
        int bucketIndex = getBucketIndex(value);
        int subBucketIndex = getSubBucketIndex(value, bucketIndex);
        int adjustedBucket = (subBucketIndex >= subBucketCount) ? (bucketIndex+1) : bucketIndex;
        return 1 << (unitMagnitude + adjustedBucket);
    }

    long lowestEquivalentValue(T value) const {
        int bucketIndex = getBucketIndex(value);
        int subBucketIndex = getSubBucketIndex(value, bucketIndex);
        return valueFromIndex(bucketIndex, subBucketIndex);
    }

    long nextNonEquivalentValue(T value) const {
        return lowestEquivalentValue(value) + sizeOfEquivalentValueRange(value);
    }

    long highestEquivalentValue(T value) const {
        return nextNonEquivalentValue(value) - 1;
    }

    long medianEquivalentValue(T value) const {
        return lowestEquivalentValue(value) + sizeOfEquivalentValueRange(value) / 2;
    }

    private long valueFromIndex(int bucketIndex, int subBucketIndex) const {
        return (cast(long)subBucketIndex) << (bucketIndex + unitMagnitude);
    }

    long countAtValue(T value) const {
        return countsGetNormalized(countsIndexFor(value));
    }

    long countAtIndex(int index) const {
        return countsGetNormalized(index);
    }

    private long countsGetDirect(int index) const {
        return counts[index];
    }

    private long countsGetNormalized(int index) const {
        return countsGetDirect(normalizeIndex(index));
    }

    int countsIndex(int bucketIndex, int subBucketIndex) const {
        /* Calculate the index for the first entry in the bucket: */
        /* (The following is the equivalent of ((bucket_index + 1) * subBucketHalfCount) ): */
        int bucketBaseIndex = (bucketIndex + 1) << subBucketHalfCountMagnitutde;
        /* Calculate the offset in the bucket: */
        int offsetInBucket = subBucketIndex - subBucketHalfCount;
        /* The following is the equivalent of ((sub_bucket_index  - subBucketHalfCount) + bucketBaseIndex; */
        return bucketBaseIndex + offsetInBucket;
    }

    int countsIndexFor(T value) const {
        int bucketIndex = getBucketIndex(value);
        int subBucketIndex = getSubBucketIndex(value, bucketIndex);
        return countsIndex(bucketIndex, subBucketIndex);
    }

    long valueAtIndex(ulong index) const {
        return valueAtIndex(cast(int)index);
    }

    long valueAtIndex(int index) const {
        int bucketIndex = (index >> subBucketHalfCountMagnitutde) - 1;
        int subBucketIndex = (index & (subBucketHalfCount - 1)) + subBucketHalfCount;

        if (bucketIndex < 0) {
            subBucketIndex -= subBucketHalfCount;
            bucketIndex = 0;
        }

        return valueFromIndex(bucketIndex, subBucketIndex);
    }

    static struct CountsIterator {
        HdrHistogram* hdr;

        this(HdrHistogram* parent) {
            hdr = parent;
        }

        int opApply(int delegate(ulong idx, long count) dg) const {
            int ret = 0;

            foreach (idx, ref count; hdr.counts) {
                if (count == 0) {
                    continue;
                }

                ret = dg(idx, count);
                if (ret) {
                    break;
                }
            }

            return ret;
        }
    }

    CountsIterator getCountsIterator() {
        return CountsIterator(&this);
    }
}

unittest {
    import std.exception;
    import std.stdio: writefln, writef;

    HdrHistogram!(long, 1, 30_000_000, 2) hist;

    hist.open();
    hist.printConfig();

    hist.put(2);
    writefln("min %d max %d mean %f stddev %f", hist.min, hist.max, hist.mean, hist.stddev(hist.mean));
    foreach (percentile; [ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 95.0, 99.0, 99.9, 99.99 ]) {
        writef("%5.2f%%=%-6d ", percentile, hist.valueAtPercentile(percentile));
    }
    writefln("");

    hist.put(30000);
    writefln("min %d max %d mean %f stddev %f", hist.min, hist.max, hist.mean, hist.stddev(hist.mean));
    foreach (percentile; [ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 95.0, 99.0, 99.9, 99.99 ]) {
        writef("%5.2f%%=%-6d ", percentile, hist.valueAtPercentile(percentile));
    }
    writefln("");
}
