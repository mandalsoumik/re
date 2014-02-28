-- program_impute.lua
-- main program to impute a missing feature
-- COMMAND LINE ARGS
-- --train INFO_COLUMN [INFO_COLUMN]
-- --test  INFO_COLUMN
-- --target PARCELS_COLUMN
-- --hpset  INTEGER
-- --output FILE_PATH
-- INPUT FILES:
-- ../output/v6/parcels-sfr-geocoded.serialized-NamedMatrix
-- ../output/v6/parcels-sfr-geocoded-info.serialized-NamedMatrix
-- ../output/v6/hpsets-impute.csv
-- OUTPUT FILES: <specified by --output command line parameter>, a CSV file with these columns
--   dataRowIndex : integer, row in parcels_nm.t for the observation
--   predicted    : string, predicted value

require 'argmax'
require 'Accumulators'
require 'distancesSurface2'
require 'dropZeroSaliences'
require 'equalObjectValues'
require 'hasNaN'
require 'ifelse'
require 'isnan'
require 'kernelEpanechnikovQuadraticKnn2'
require 'ModelLogreg'
require 'ModelNaiveBayes'
require 'NamedMatrix'
require 'LapTimer'
require 'printAllVariables'
require 'printTableValue'
require 'printTableVariable'
require 'splitString'
require 'standardize'
require 'tableCopy'
require 'time'
require 'Timer'
require 'torch'
-- require 'view1DAS2D'

-- return table containing checked values from parsed command line
-- make sure output file is writable
local function parseAndCheckArg(arg)

   local function parseCommandLine(arg)
      local vp = makeVp(0, 'parseCommandLine')
      local clArgs = {}
      local index = 1
      while index <= #arg do
         local keyword = arg[index]
         local field = string.sub(keyword, 3)
         index = index + 1
         vp(1, 'keyword', keyword, 'field', field, 'index', index)
         if keyword == '--cache' then
            --  these keywords have no argument
            clArgs[field] = true
         elseif keyword == '--hpset' or
            keyword == '--output' or 
            keyword == '--target' then
            -- these keywords have a single argument
            clArgs[field] = arg[index]
            index = index + 1
         elseif keyword == '--train' or 
                keyword == '--test' then
            -- these keywords may have 1 or more arguments
            local columns = {}
            repeat
               table.insert(columns, arg[index])
               index = index + 1
            until index > #arg or string.sub(arg[index], 1, 1) == '-'
            clArgs[field] = columns
         else
            error('invalid command line argument: ' .. keyword)
         end
      end
      return clArgs
   end

   local function checkArgs(clArgs)
      local vp, verboseLevel = makeVp(0, 'checkArgs')
      vp(1, '***')
      if verboseLevel > 0 then printTableValue('clArgs', clArgs) end
      local function checkPresent(field, atmost)
         assert(clArgs[field] ~= nil, string.format('missing command line arg --%s', field))
         if atmost then
            assert(#clArgs[field] <= atmost, string.format('more than %d values for --%s', atmost, field))
         end
      end

      checkPresent('hpset')
      checkPresent('output')
      checkPresent('target')
      checkPresent('test', 2)
      checkPresent('train')

      clArgs.hpset = tonumber(clArgs.hpset)
      assert(clArgs.hpset, '--hpset not an integer')
      assert(clArgs.hpset > 0)

      -- make sure we can write the output file
      local fileOutput, errorMessage = io.open(clArgs.output, 'w')
      if fileOutput == nil then
         error(errorMessage)
      end

      return clArgs
   end
   
   local function convertTypes(clArgs)
      clArgs.hpset = tonumber(clArgs.hpset)
   end

   local vp = makeVp(0, 'parseAndCheckArg')
   vp(1, 'arg', arg)
   local clArgs = parseCommandLine(arg)
   checkArgs(clArgs)
   convertTypes(clArgs)

   return clArgs
end

-- return input files as NamedMatric: hpSets, info, parcels
local function readInput()
   -- specify input files
   local fileParcels = '../data/v6/output/parcels-sfr-geocoded.serialized-NamedMatrix'
   local fileInfo =    '../data/v6/output/parcels-sfr-geocoded-info.serialized-NamedMatrix'
   local fileHpsets =  '../data/v6/output/hpsets-impute.csv'

   -- read the input files
   local parcelsNm = torch.load(fileParcels)
   local infoNm = torch.load(fileInfo)
   local hpSetsNm = NamedMatrix.readCsv{
      file=fileHpsets,
      sep=',',
      nanString='',
      nRows=-1,
      numberColumns={'k', 'lambda', 'mPerYear'},
      skip=0
   }

   return hpSetsNm, infoNm, parcelsNm
end

-- return 1D or 2D Tensor with specified columns and rows
-- ARGS
-- fromNm     : NamedMatrix
-- columnsSeq : sequence of strings or a single string, names of columns in fromNm
-- infoNm     ; 0/1 NamedMatrix
-- rows       : sequence (length 1 or 2) of column names in infoNm
--              the AND of these specifies the rows to select
local function extract(fromNm, columnsSeq, infoNm, rows)
   -- examine each selected row, calling action(<row index in fromNm.t>)
   local function examine(action)
      local vp, verboseLevel = makeVp(0, 'examine')

      -- return sequence of column indices
      local function makeSelectedColumnIndices(nm, columnNames)
         local vp, verboseLevel = makeVp(0, 'makeSelectedColumnIndices')
         vp(1, 'columnNames', columnNames)   

         local result = {}
         for i, columnName in ipairs(columnNames) do
            table.insert(result, nm:columnIndex(columnName))
         end
         if verboseLevel > 0 then 
            vp(1, 'result', result) 
            printTableValue('result', result) 
         end
         return result
      end
     
      local cOne = infoNm:columnIndex(rows[1])
      local cTwo = nil
      if #rows == 2 then
         cTwo = infoNm:columnIndex(rows[2])
      end
      vp(2, 'cOne', cOne, 'cTwo', cTwo)

      local function isSelectedRow(inputRowIndex)
         local vp = makeVp(0, 'isSelectedRow')
         vp(1, 'inputRowIndex', inputRowIndex)
         if #rows == 1 then
            return infoNm.t[inputRowIndex][cOne] == 1
         elseif #rows == 2 then
            return infoNm.t[inputRowIndex][cOne] == 1 and infoNm.t[inputRowIndex][cTwo] == 1
         else
            error('bad #rows = ' .. tostring(#rows) .. '; rows = ' .. tostring(rows))
         end
      end

      -- start body of examine() 
      for i = 1, fromNm.t:size(1) do
         if isSelectedRow(i) then
            vp(1, 'selected row index', i)
            action(i)
         end
      end
   end
   
   -- return number of rows in the result
   local function determineNumberOfResultRows()
      local vp = makeVp(0, 'determineNumberOfResultRows')
      local rowsInResult = 0

      local function countRows(selectedRowIndex)
         local vp = makeVp(0, 'countRows')
         vp(1, 'selectedRowIndex', selectedRowIndex)
         rowsInResult = rowsInResult + 1
         if rowsInResult % 100000 == 0 then
            print('counted row in result ' .. tostring(rowsInResult))
         end
      end

      examine(countRows)
      vp(1, 'rowsInResult', rowsInResult)
      assert(rowsInResult > 0, 'no rows in result: ' .. tostring(rowsInResult))
      return rowsInResult
   end
   
   -- return number of columns in the result
   local function determineNumberOfResultColumns(columnsSeq)
      return ifelse(type(columnsSeq) == 'string', 1, #columnsSeq)
   end
   
   -- return sequence of columns we want in the source
   local function makeSelectedColumnIndices(sourceNm, columnNames)
      local vp = makeVp(1, 'makeSelectedColumnIndices')
      vp(1, 'columnNames', columnNames)
      if type(columnNames) == 'string' then
         return makeSelectedColumnIndices(sourceNm, {columnNames})
      else  
         local result = {}
         for _, columnName in ipairs(columnNames) do
            table.insert(result, sourceNm:columnIndex(columnName))
         end
         vp(1, 'result', result)
         return result
      end
   end

   -- body of extract() starts here
   local vp = makeVp(2, 'extract')
   vp(1, 'columnsSeq', columnsSeq, 'rows', rows)

   -- allocate the result Tensor
   -- if one column, return 1D, otherwise return 2D
   local rowsInResult = determineNumberOfResultRows()
   local columnsInResult = determineNumberOfResultColumns(columnsSeq)
   vp(2, 'columsSeq', columnsSeq)
   vp(2, 'rowsInResult', rowsInResult, 'columnInResult', columnsInResult)
   local result
   if columnsInResult == 1 then
      result = torch.Tensor(rowsInResult)
   else  
      result = torch.Tensor(rowsInResult, columnsInResult)
   end
   vp(2, 'result:size()', result:size())

   local selectedColumnIndices = makeSelectedColumnIndices(fromNm, columnsSeq)
   vp(2, 'selectedColumnIndices', selectedColumnIndices)

   -- insert elements in the result Tensor
   local nextResultRowIndex = 0
   local function buildResult(selectedRowIndex)
      nextResultRowIndex = nextResultRowIndex + 1
      if nextResultRowIndex % 100000 == 0 then
         print('extracting result row ' .. tostring(nextResultRowIndex))
      end
      for i, selectedColumnIndex in ipairs(selectedColumnIndices) do
         if columnsInResult == 1 then
            result[nextResultRowIndex] = fromNm.t[selectedRowIndex][selectedColumnIndex]
         else
            result[nextResultRowIndex][i] = fromNm.t[selectedRowIndex][selectedColumnIndex]
         end
      end
   end
   
   examine(buildResult)  -- add each selected row and column to the result

   return result
end

-- return data table
-- the cache is a table containing two fields: clArgs and data
-- data is a table containing the training and testing data, both X and y components
local function readCacheOrBuildData(clArgs, config)

   -- return table containing requested hyperparameters
   local function extractHyperparameters(setNumber, hpSetsNm)
      return {
         k = hpSetsNm:get(setNumber, 'k'),
         lambda = hpSetsNm:get(setNumber, 'lambda'),
         mPerYear = hpSetsNm:get(setNumber, 'mPerYear')
      }
   end
       

   -- read all the data and extract the portions we want
   local function readAndExtractData(clArgs, config)
      
      local function extract5(rowSelection, infoNm, parcelsNm)
         local function extract1(columnSelection)
            return extract(parcelsNm, columnSelection, infoNm, rowSelection)
         end

         local location = {}
         for k, v in pairs(config.columnNamesLocation) do
            location[k] = extract1(v)
         end

         return {
            X=extract1(config.columnNamesInput),
            y=extract1(clArgs.target),
            location=location,
            parcelsFileNumber=extract1(config.columnNameParcelFileNumber),
            parcelsRecordNumber = extract1(config.columnNameParcelRecordNumber)
         }
      end

      local hpSetsNm, infoNm, parcelsNm = readInput()

      local data = {train = {}, test = {}, hp = {}}

      data.hp = extractHyperparameters(clArgs.hpset, hpSetsNm)

      data.train = extract5(clArgs.train, infoNm, parcelsNm)
      data.test = extract5(clArgs.test, infoNm, parcelsNm)

      -- standardize the X valus in the training data
      local XStandardized, means, stdvs = standardize(data.train.X)
      data.train.XStandardized = XStandardized
      data.train.XStandardizedMeans = means
      data.train.XStandardizedStdvs = stdvs
      data.test.XStandardized = standardize(data.test.X, means, stdvs)
      return data
   end

   -- return true if the cache's command line args are the same as the program's
   local function sameArgs(program, cache)
      for k, v in pairs(program) do
         if not equalObjectValues(v, cache[k]) then
            return false
         end
      end
      return true
   end

   -- return path to the cache file
   local function pathToCacheFile(programName)
      return '../data/v6/output/' .. programName .. '-cache.serialized'
   end

   -- return cache for the program, if it exists; otherwise, return nil
   local function loadCache(config)
      -- check if cache file exists
      local path = pathToCacheFile(config.programName)
      local f, errorMsg = io.open(path, 'r')
      if f == nil then
         return nil  -- cache file does not exist
      else
         f:close()
         return torch.load(path)
      end
   end

   -- write the cache file for the program
   local function saveCache(config, cache)
      torch.save(pathToCacheFile(config.programName), cache)
   end

   -- main body of readCacheOrBuildData()
   local vp = makeVp(0, 'readCacheOrBuildData')
   vp(1, 'clArgs', clArgs, 'programName', programName)
   if clArgs.cache then
      local cache = loadCache(config) -- return cache from disk if it exists
      vp(1, 'cache', cache)
      if cache ~= nil and sameArgs(clArgs, cache.clArgs) and cache.cacheVersion == config.cacheVersion then
         vp(2, 'using cache')
         return cache.data
      else
         -- either no cache or the cache is for a different set of command line args
         vp(2, 'creating cache')
         local data = readAndExtractData(clArgs, config)
         cache = {clArgs = clArgs, data = data, cacheVersion = config.cacheVersion}
         saveCache(config, cache)
         return data
      end
   else
      return readAndExtractData(clArgs, config)
   end
end

-- determine kernelized weights of training locations from a query location
-- RETURN
-- weights  : 1D Tensor
-- lapTable : table; key = lapname, value ={cpu,wallclock}
-- err      : optional string, not nil if there was an error
local function makeWeights(trainLocation, queryLocation, mPerYear, k, testIndex)
   assert(k > 1)
   local lapTimer = LapTimer()
   
   local distances = distancesSurface2(queryLocation, trainLocation, mPerYear)
   lapTimer:lap('distances')

   local weights, err = kernelEpanechnikovQuadraticKnn2(distances, k)
   lapTimer:lap('weights')

   local lapTimes = lapTimer:getTimes()
   return weights, lapTimes, err
end 

local function makeQueryLocation(locations, index)
   return {
      latitude = locations.latitude[index],
      longitude = locations.longitude[index],
      year = locations.year[index],
   }
end

local function writeNonZeroSaliences(saliences)
   print('nonzero saliences;')
   for i = 1, saliences:size(1) do
      if saliences[i] ~= 0 then
         print(string.format(' %d->%f', i, saliences[i]))
      end
   end
end

-- create Model and fit it, returning model, optimalTheta, fitInfo
-- reduce size of model by eliminating training samples with 0 salience
local function fitModelLogreg(X, y, s, nClasses, fittingOptions)
   local hasNonZeroSalience = torch.ne(s, 0)
   local nReducedSample = torch.sum(hasNonZeroSalience)
   
end

local function makeWritePredictions(outputPath)
   local outFile, err = io.open(outputPath, 'w')
   if err ~= nil then
      error(err)
   end

   -- write CSV header record
   local function writeHeader(nPredictions)
      outFile:write('fileNumber,recordNumber')
      for n = 1, nPredictions do
         outFile:write(',prediction_' .. tostring(n)) -- use underscore to make parsing column names easier
      end
      outFile:write('\n')
   end

   local headerWritten = false

   -- write data record
   local function writePredictions(predictions, parcelsFileNumber, parcelsRecordNumber, testIndex)
      local vp = makeVp(2, 'writePredictions')
      vp(1, 'predictions', predictions,  
            'parcelsFileNumber', parcelsFileNumber, 
            'parcelsRecordNumber', parcelsRecordNumber, 
            'testIndex', testIndex)
      if not headerWritten then
         writeHeader(predictions:size(1))
         headerWritten = true
      end

      -- write the data record
      outFile:write(string.format('%d,%d', parcelsFileNumber, parcelsRecordNumber))
      for i = 1, predictions:size(1) do
         outFile:write(string.format(',%f', predictions[i]))
      end
      outFile:write('\n')
   end
   
   local function closePredictionsFile()
      outFile:close()
   end

   return writePredictions, closePredictionsFile
end

local function analyzeEvaluations(evaluations, fitCpu, fitWallclock)
   local nEpochs = #evaluations

   -- display loss at end of each epoch
   local counts = {}
   print('fitInfo.evaluations')
   for i, info in ipairs(evaluations) do
      local why = info[1]
      local stepsize = info[2]
      local loss = info[3]
      counts[why] = (counts[why] or 0) + 1
      print(string.format(' %6s stepsize %18.15f loss %17.15f', why, stepsize, loss))
   end
   
   local function printCount(which, num)
      print(string.format('count %13s = %d', which, num))
   end

   local totalCount = 0
   for k, v in pairs(counts) do
      totalCount = totalCount + v
      printCount(k, v)
   end
   printCount('total', totalCount)
   local epochsWithProgress = counts['step'] + (counts['adjust'] / 3)
   printCount('with progress', epochsWithProgress)

   print('fraction of epochs progressing the computation = ', epochsWithProgress / nEpochs)
   print(string.format('per epoch cpu       = %17.15f', fitCpu / nEpochs))
   print(string.format('per epoch wallclock = %17.15f', fitWallclock / nEpochs))
end

-- return best step size based on grid search for initial step size
local function findBestInitialStepSize(X, y, s, nClasses, fittingOptions)
   local vp = makeVp(0, 'findBestInitialStepSize')
   
   local function getLoss(initialStepSize, nEpochs)
      local model = ModelLogreg(X, y, s, nClasses)
      
      -- change the fitting options
      myFittingOptions = tableCopy(fittingOptions)

      -- change certain methodOptions
      myFittingOptions.methodOptions.initialStepSize = initialStepSize
      myFittingOptions.methodOptions.nEpochsBeforeAdjustingStepSize = 10 * nEpochs -- never adjust the stepsize
      myFittingOptions.methodOptions.nEpochsToAdjustStepSize = nEpochs       -- fitter will adjust on the first step
      myFittingOptions.methodOptions.nextStepSizes = function(stepSize)  return {stepSize} end

      -- entirely replace the converge criteria
      myFittingOptions.convergence = {
         maxEpochs = nEpochs,  -- run number of epochs specified
      }

      local _, fitInfo = model:fit(myFittingOptions)
      return fitInfo.finalLoss
   end

   local verbose = false
   local initialStepSizes = {.3, 1, 3, 10, 30}
   local nEpochs = 2    -- a test shows that get same initial step size for nEpochs = 2, 3, 10
   vp(2, 'original fittingOptions', fittingOptions)

   local bestInitialStepSize = nil
   local bestLoss = math.huge
   for _, initialStepSize in ipairs(initialStepSizes) do
      local loss = getLoss(initialStepSize, nEpochs)
      if verbose then
         print('find best initial step size', initialStepSize, loss)
      end
      if loss < bestLoss then
         bestLoss = loss
         bestInitialStepSize = initialStepSize
      end
   end

   vp(2, 'restored? fittingOptions', fittingOptions)

   vp(1, 'bestInitialStepSize', bestInitialStepSize)
   return bestInitialStepSize
end

-- return reduced X, y, and s and possible error
-- return standardized X values
-- RETURNS
-- reducedX ; 2D Tensor
-- reducedY : 1D Tensor
-- reducedS ; 1D Tensor
-- lapTimer : LapTimer containing times
-- errorMsg : optional string
local function reduceToKTrainingSamples(data, testIndex)
   local vp = makeVp(2, 'reduceToKTrainingSamples')
   local lapTimer = LapTimer()
   local saliences, makeWeightsTimes, err = makeWeights(data.train.location, 
                                         makeQueryLocation(data.test.location, testIndex),
                                         data.hp.mPerYear, 
                                         data.hp.k,
                                         testIndex)
   lapTimer:lap('makeWeights')
   if err then
      return nil, nil, nil, lapTimer:getTimes(), err
   else
      -- drop samples that have zero salience
      -- this will be most of them, as about 600,000 samples and 60 with zero salience
      local reducedX, reducedY, reducedS = dropZeroSaliences(data.train.XStandardized,
                                                             data.train.y,
                                                             saliences)
      assert(reducedS:size(1) > 1)
      lapTimer:lap('dropZeroSaliences')
      return reducedX, reducedY, reducedS, lapTimer:getTimes(), nil
   end
end
   
-- predict use local linear regression
-- RETURNS
-- predictions    : 2D Tensor
-- predictionInfo : table
-- nCalls         : table with number of calls to each method in the fitting procedure
-- IN/OUT ARGS
-- lapTimer
local function predictUsingLLR(X, y, s, newX, nClasses, lambda, bestInitialStepSizes, lapTimer)

   local function setInitialFittingOptions()
      local function nextStepSizes(currentStepSize)
         return {currentStepSize, .5 * currentStepSize, 1.5 * currentStepSize}
      end
      local fittingOptions = {
         method = 'bottou',
         sampling = 'epoch',
         methodOptions = {
            printLoss = false,
            initialStepSize = 1,
            nEpochsBeforeAdjustingStepSize = 10,
            nEpochsToAdjustStepSize = 1,
            nextStepSizes = nextStepSizes,
         },
         samplingOptions = {},  -- no sampling options when sampling == 'epoch'
         convergence = {  -- these will need to be tuned
         maxEpochs = 1000,
         toleranceLoss = 1e-4, 
         },
      regularizer = {
         L2 = lambda,
         },
      }

      return fittingOptions
   end

   local vp, verboseLevel = makeVp(0, 'predictUsingLLR')
   local debug = verboseLevel > 0
     

   -- set the fitting options
   -- grid search for best initial step size
   local fittingOptions = setInitialFittingOptions()
   local bestInitialStepSize = findBestInitialStepSize(X, y, s, nClasses, fittingOptions)
   fittingOptions.methodOptions.initialStepSize = bestInitialStepSize -- finalize fitting options
   if verboseLevel > 0 then 
      printTableValue('fittingOptionsLLR', fittingOptionsLLR)
   end

   -- keep track of best sizes
   -- perhaps we can optimize the search
   bestInitialStepSizes[bestInitialStepSize] = (bestInitialStepSizes[bestInitialStepSize] or 0) + 1
   lapTimer:lap('LLR find best initial step size')

   -- build and fit the model
   local model = ModelLogreg(X, y, s, nClasses)

   local function fit(fittingOptions)
      return model:fit(fittingOptions)
   end

   local fitCpu, fitWallclock, optimalTheta, fitInfo = time('both', fit, fittingOptions)
   lapTimer:lap('LLR construct and fit model')
-- print('number of function calls in Objectivefunction to fit the model')
-- printTableValue('fitInfo.nCalls', fitInfo.nCalls)
   if false then
      analyzeEvaluations(fitInfo.evaluations, fitCpu, fitWallclock)
   end
   if debug then 
      vp(2, 'testIndex', testIndex, 'fitInfo', fitInfo) 
   end

   -- fit the test sample using the model
   local predictions, predictionInfo = model:predict(newX, optimalTheta)
   lapTimer:lap('LLR predict one test sample')

   return predictions, predictionInfo, fitInfo.nCalls
end


-- predict using local naive bayes
-- RETURNS
-- predictions : 2D Tensor
-- predictInfo : table
-- IN/OUT args
-- mutate lapTimer
local function predictUsingLNB(X, y, newX, nClasses, lapTimer)
   local vp, verboseLevel = makeVp(0, 'predictUsingNB')

   -- set the fitting options for NB = naive bayes
   local fittingOptions = {
      method = 'gaussian',
   }

   local model = ModelNaiveBayes(X, y, nClasses)
   vp(2, 'model', model)

   local optimalTheta, fitInfo = model:fit(fittingOptions)
   lapTimer:lap('LNB construct and fit model')
   vp(2, 'optimalTheta', optimalTheta, 'fitInfo', fitInfo)

   local predictions, predictionInfo = model:predict(newX, optimalTheta)
   lapTimer:lap('LNB predict one test sample')
   vp(2, 'predictions', predictions, 'predictionInfo', predictionInfo)
   if verboseLevel > 1 then 
      timer:write()
   end

   return predictions, predictionInfo
end


-- return true if the predictions are correct
-- NOTE; if predictionProbabilities is all NaNs, then
--   - c was not in the training data for some class C; and
--   - every other training sample had just one occurrence of class C:w
local function isCorrect(actual, predictionProbabilities)
   local vp = makeVp(0, 'isCorrect')
   vp(1, 'actual', actual, 'predictionProbabilities', predictionProbabilities)
   local predicted = argmax(predictionProbabilities)
   vp(2, 'predicted', predicted)

   local result = actual == predicted
   vp(1, 'result', result)
   return result
end

-- print times
local function printTimes(nTestSamples, lapTimer, lnbLapTimes, llrLapTimes, llrNCalls)
   local vp = makeVp(0, 'printTimes')
   vp(1, 'nTestSamples', nTestSamples, 
         'lapTimer', lapTimer, 
         'lnbLapTimes', lnbLapTimes, 
         'llrLapTimes', llrLapTimes,
         'llrNCalls', llrNCalls)


   -- sort lapnames
   local lapnames = {}
   for lapname, _ in pairs(lapTimer:getTimes()) do
      table.insert(lapnames, lapname)
   end
   table.sort(lapnames)
   
   print()
   if jit then
      print('timings using JIT')
   else
      print('timings without JIT')
   end

   local format = '%-35s cpu %15.6f wallclock %15.6f'
   
   if false then
      print()
      print(string.format('cumulative timings across all %d test samples', nTestSamples))
      for _, lapname in ipairs(lapnames) do
         local times = lapTimer:getTimes()[lapname]
         print(string.format(format, lapname, times.cpu, times.wallclock))
      end
   end

   print()
   print('average per-test sample timings')
   local llrCpu, llrWallclock = 0, 0
   local lnbCpu, lnbWallclock = 0, 0
   for _, lapname in ipairs(lapnames) do
      local times = lapTimer:getTimes()[lapname]
      print(string.format(format, 
                          lapname, times.cpu / nTestSamples, times.wallclock / nTestSamples))
      if string.sub(lapname, 1, 3) == 'LLR' then
         llrCpu = llrCpu + times.cpu
         llrWallclock = llrWallclock + times.wallclock
      elseif string.sub(lapname, 1, 3) == 'LNB' then
         lnbCpu = lnbCpu + times.cpu
         lnbWallclock = lnbWallclock + times.wallclock
      end
   end
   local prefix = 'total per-sample times for '
   print()
   print(string.format(format, prefix .. 'LLR', 
                       llrCpu / nTestSamples, llrWallclock / nTestSamples))
   print(string.format(format, prefix .. 'LNB', 
                       lnbCpu / nTestSamples, lnbWallclock / nTestSamples))

   
   print()
   print('LLR time estimate for average lossGradient call')
   print('nTestSamples', nTestSamples)
   local nLossGradient = llrNCalls:getTable()['lossGradient']
   print('number of calls to lossGradient', nLossGradient)

   -- average time for lossGradient
   local cfTimes = lapTimer:getTimes()['LLR construct and fit model'] 
   local cfCpu, cfWallclock = cfTimes.cpu, cfTimes.wallclock
   print(string.format('elapsed time to construct and fit: cpu %15.6f wallclock %15.6f', cfCpu, cfWallclock))
   print(string.format('average time for lossGradient    : cpu %15.6f wallclock %15.6f', 
                       cfCpu/nLossGradient, cfWallclock / nLossGradient))
   
end

-- return new table that sums up cpu and wallclock times for lap in both tables
local function sumLapTimes(table1, table2)
   assert(type(table1) == 'table')
   assert(type(table2) == 'table')
   local result = {}

   for lapname, value1 in pairs(table1) do
      local value2 = table2[k]
      if value2 == nil then
         value2 = {cpu = 0, wallclock = 0}
      end
      result[lapname] = {cpu = value1.cpu + value2.cpu, wallclock = value1.wallclock + value2.wallclock}
   end

   printTableValue('table1', table1)
   printTableValue('table2', table2)
   printTableValue('result', result)
   stop()
   return result
end

      
-------------------------------------------------------------------------------
-- MAIN PROGRAM
-------------------------------------------------------------------------------

local vp, verboseLevel = makeVp(2, 'program_impute')

-- configure
local config = {
   programName = 'program_impute',
   cacheVersion = 1,
   cacheVersion = 2, -- forgot to record changes
   cacheVersion = 3, -- split location into 3 specifically-named fields
   cacheVersion = 4, -- standardize X values in the training data
   cacheVersion = 5, -- also standardize X values in the test data
   -- define column names in the parcels files
   columnNamesInput = {  
      -- location
      'G LATITUDE',
      'G LONGITUDE',
      'YEAR.BUILT',
      -- description
      'BEDROOMS',
      'LAND.SQUARE.FOOTAGE',
      'PARKING.SPACES',
      'TOTAL.BATHS.CALCULATED',
      'UNIVERSAL.BUILDING.SQUARE.FEET'
   },
   columnNamesLocation = {  -- in parcels file
      latitude = 'G LATITUDE',
      longitude = 'G LONGITUDE',
      year = 'YEAR.BUILT'
   },
   columnNameParcelFileNumber = 'parcel.file.number',
   columnNameParcelRecordNumber = 'parcel.record.number',
   }
printTableValue('config', config)

local clArgs = parseAndCheckArg(arg)
printTableValue('clArgs', clArgs)

-- make sure we can write the predictions
local writePredictions, closePredictionsFile = makeWritePredictions(clArgs.output)

-- read the input
local cpu, data = time('cpu', readCacheOrBuildData, clArgs, config)
print('cpu secs to read and build data =', cpu)
printTableValue('data', data)


-- create and run a local logistic regression model for each test sample
local nClasses = torch.max(data.test.y)
local nFeatures = data.train.X:size(2)
local nTestSamples = data.test.y:size(1)
vp(2, 'nClasses', nClasses, 'nFeatures', nFeatures, 'nTestSamples', nTestSamples)

local lapTimer= LapTimer()

local llrNCalls = Accumulators()

local debug = true
local bestInitialStepSizes = {}

local nCorrectLLR = 0
local nCorrectLNB = 0



for testIndex = 1, nTestSamples do
   -- extract standardized X subset of samples
   local reducedX, reducedY, reducedS, reductionLapTime, err = reduceToKTrainingSamples(data, testIndex)
   lapTimer:lap('reduce to k samples')

   if err then
      print(string.format('unable to reduce number of samples for testIndex %d reason %s', testIndex, err))
      error(err)  -- for now, later continue
   else
      local newX = data.test.XStandardized:sub(testIndex, testIndex)
      --vp(2, 'newX', newX)
      
      local predictionsLLR, predictInfoLLR, nCalls = 
         predictUsingLLR(reducedX, reducedY, reducedS, newX, nClasses, data.hp.lambda, bestInitialStepSizes, lapTimer)
      assert(not hasNaN(predictionsLLR))

      llrNCalls:addTable(nCalls)

      local predictionsLNB, predictInfoNB = predictUsingLNB(reducedX, reducedY, newX, nClasses, lapTimer)
      if hasNaN(predictionsLNB) then
         -- verify that either class C is not present or class C has exactly one training sample
         print('found NaN in predictions LNB')
         if true then
            for i = 1, reducedX:size(1) do
               print(string.format('sample index %d sample class %d', i, reducedY[i]))
            end
            error('found NaN')
         end
      end

      if false then
         vp(2, ' ')
         vp(2, '****')
         vp(2, 'predictionsLLR', predictionsLLR,
               'predictionsLNB', predictionsLNB,
               'actual', data.test.y[testIndex])
      end

      if false then
         -- TODO: fix this code 
         -- write predictions for test sample
         writePredictions(predictions[1],   -- convert 1 x N to just N, dropping first dimension
         data.test.parcelsFileNumber[testIndex], 
         data.test.parcelsRecordNumber[testIndex], 
         testIndex)
         timer:lap('write predictions')
      end

      -- keep track of accuracy
      -- NOTE: could also use the precomputed maximum likelihood values in predictInfoXXX
      local actual = data.test.y[testIndex]
      nCorrectLLR = nCorrectLLR + ifelse(isCorrect(actual, predictionsLLR[1]), 1, 0)
      nCorrectLNB = nCorrectLNB + ifelse(isCorrect(actual, predictionsLNB[1]), 1, 0)

      -- periodically write status
      if testIndex % 1 == 0 then
         print(string.format('testIndex %d nCorrectLLR %d nCorrectLNB %d', testIndex, nCorrectLLR, nCorrectLNB))
         --timerLLR:write()
         --timerLNB:write()
      end

      --   periodically write best initial step sizes and other info
      if testIndex % 1 == 0 and false then
         print('best initial step sizes at testIndex', testIndex)
         for k, v in pairs(bestInitialStepSizes) do
            print(string.format(' %f was used %d times', k, v))
         end
         print('toleranceLoss', fittingOptions.convergence.toleranceLoss, 'accuracy', nAccurate / testIndex)
         printTableValue('data.hp', data.hp)
      end

      if testIndex % 100  == 0 then
         print('\n************************************************************')
         printTimes(testIndex, lapTimer, lnbLapTimes, llrLapTimes, llrNCalls)
         print()
         print('nCorrectLLR', nCorrectLLR)
         print('nCorrectLNB', nCorrectLNB)
         print('\n*************************************************************\n')
      end

      lapTimer:lap('tracking and reporting')
   end
end
closePredictionsFile()
   

error('write more')

stop()
