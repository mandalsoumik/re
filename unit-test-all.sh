# unit-test-all.sh
# run all unit tests

torch argmax_test.lua
torch assertEq_test.lua
torch asColumnMatrix_test.lua
torch asFactor_test.lua
torch augment_test.lua
torch bestApns_test.lua
torch bytesIn_test.lua
torch bytesIn_test.lua
torch CacheFile_test.lua
torch concatHorizontal_test.lua
torch Dataframe_test.lua
torch distancesSurface_test.lua
torch equalObjects_test.lua
torch equalTensors_test.lua
torch extract_test.lua
torch extractTensor_test.lua
torch hasNA_test.lua
torch hasNaN_test.lua
torch head_test.lua
torch ifelse_test.lua
torch isnan_test.lua
torch isSequence_test.lua
torch kernelEpanechnikovQuadraticKnn_test.lua
torch keys_test.lua
torch makeDistanceSurface_test.lua
torch makeLogreg_test.lua
torch makeNextNonZeroImportanceIndex_test.lua
torch makeNextPermutedIndex_test.lua
torch makeSampler_test.lua
torch makeSampleIndexer_test.lua
torch maxIndex_test.lua
torch memoizedComputationOnDisk_test.lua
torch memoryUsed_test.lua
torch metersPerLatitudeDegree_test.lua
torch metersPerLongitudeDegree_test.lua
torch ModelLinearL2Loss_test.lua
torch NamedMatrix_test.lua
torch parseCommandLine.lua
torch sequenceContains_test.lua
torch sgdBottou_test.lua
torch standardize_test.lua
torch softmaxes_test.lua
torch splitTensor_test.lua
torch SliceReader_test.lua
torch Timer_test.lua
torch unique_test.lua
torch validateAttributes_test.lua
torch view1DAs2D_test.lua
torch viewAsColumnVector_test.lua
torch viewAdditionalRows_test.lua
echo "ALL UNIT TESTS COMPLETED"

