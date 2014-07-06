require 'dp'
require 'cutorch'
require 'cunn'
require 'cunnx'

--[[command line arguments]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a Language Model on BillionWords dataset using Conditional Computation SoftmaxTree')
cmd:text('Example:')
cmd:text('$> th conditionalcomputation.lua --small --batchSize 512 ')
cmd:text('$> th conditionalcomputation.lua --tiny --batchSize 512 ')
cmd:text('Options:')
cmd:option('--learningRate', 0.1, 'learning rate at t=0')
cmd:option('--decayPoint', 100, 'epoch at which learning rate is decayed')
cmd:option('--decayFactor', 0.1, 'factory by which learning rate is decayed at decay point')
cmd:option('--maxOutNorm', 0, 'max norm each layers output neuron weights')
cmd:option('--batchSize', 512, 'number of examples per batch')
cmd:option('--useDevice', 1, 'sets the device (GPU) to use')
cmd:option('--maxEpoch', 400, 'maximum number of epochs to run')
cmd:option('--maxTries', 30, 'maximum number of epochs to try to find a better local minima for early-stopping')
--cmd:option('--dropout', false, 'apply dropout on hidden neurons, requires "nnx" luarock')

cmd:option('--contextSize', 5, 'number of words preceding the target word used to predict the target work')
cmd:option('--inputEmbeddingSize', 128, 'number of neurons per word embedding')

--[[ conditional model ]]--
cmd:option('--hiddenSize', '{1024,1024}', 'number of units used for the hidden layers of the conditional model')
cmd:option('--windowSize', '{128,128}', 'number of neurons or blocks used per example')
cmd:option('--noiseStdv', '{1,1}', 'standard deviation of gaussian noise used for NoisyReLU or WindowGate')
cmd:option('--gaterSize', '{128,128}', 'the output (windowsparse) or hidden (blocksparse) size of gaters')

-- blocksparse
cmd:option('--nBlock', '{256,256}', 'number of blocks used in the hidden layers of the BlockSparse models')

-- windowsparse
cmd:option('--windowSparse', false, 'use WindowSparse instead of BlockSparse (not recommended)')
cmd:option('--inputStdv', '{2,2}', '')
cmd:option('--outputStdv', '{32,32}', '')
cmd:option('--windowLR', '{0.5,0.5}', '')


--[[ output layer ]]--
cmd:option('--outputEmbeddingSize', 128, 'number of hidden units at softmaxtree')
cmd:option('--softmaxtree', false, 'use the softmaxtree instead of the inefficient (full) softmax')

--[[ data ]]--
cmd:option('--small', false, 'use a small (1/30th) subset of the training set')
cmd:option('--tiny', false, 'use a tiny (1/100th) subset of the training set')
cmd:option('--trainEpochSize', 1000000, 'number of train examples seen between each epoch')
cmd:option('--validEpochSize', 100000, 'number of valid examples used for early stopping and cross-validation') 

cmd:text()
opt = cmd:parse(arg or {})
print(opt)


--[[data]]--
local train_file = 'train_data.th7' 
if opt.small then 
   train_file = 'train_small.th7'
elseif opt.tiny then 
   train_file = 'train_tiny.th7'
end

local datasource = dp.BillionWords{
   context_size = opt.contextSize, train_file = train_file
}

--[[Model]]--
cutorch.setDevice(opt.useDevice)

print("Input to first hidden layer has "..
   opt.contextSize*opt.inputEmbeddingSize.." neurons.")

local conditionalModel
if opt.windowSparse then
   print"Using WindowSparse conditional model"
   conditionalModel = dp.WindowSparse{
      input_size = opt.contextSize*opt.inputEmbeddingSize, 
      output_size = opt.outputEmbeddingSize,
      hidden_size = table.fromString(opt.hiddenSize),
      gater_size = table.fromString(opt.gaterSize),
      window_size = table.fromString(opt.windowSize),
      input_stdv = table.fromString(opt.inputStdv),
      output_stdv = table.fromString(opt.outputStdv),
      noise_stdv = table.fromString(opt.noiseStdv),
      lr = table.fromString(opt.windowLR)
   }
else
   conditionalModel = dp.BlockSparse{
      input_size = opt.contextSize*opt.inputEmbeddingSize, 
      output_size = opt.outputEmbeddingSize,
      n_block = table.fromString(opt.nBlock),
      hidden_size = table.fromString(opt.hiddenSize),
      gater_size = table.fromString(opt.gaterSize),
      window_size = table.fromString(opt.windowSize),
      noise_std = table.fromString(opt.noiseStdv)
   }
end

local softmax
if opt.softmaxtree then
   softmax = dp.SoftmaxTree{
      input_size = opt.outputEmbeddingSize, 
      hierarchy = datasource:hierarchy(),
      root_id = 880542,
      dropout = opt.dropout and nn.Dropout() or nil
   }
else
   print("Warning: you are using full LogSoftMax for last layer, which "..
      "is really slow (800,000 x outputEmbeddingSize multiply adds "..
      "per example. Try --softmaxtree instead.")
   softmax = dp.Neural{
      input_size = opt.outputEmbeddingSize,
      output_size = table.length(datasource:classes()),
      transfer = nn.LogSoftMax(),
      dropout = opt.dropout and nn.Dropout() or nil
   }
end

mlp = dp.Sequential{
   models = {
      dp.Dictionary{
         dict_size = datasource:vocabularySize(),
         output_size = opt.inputEmbeddingSize
      },
      conditionalModel,
      softmax
   }
}

mlp:cuda()

--[[Propagators]]--
train = dp.Optimizer{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   visitor = { -- the ordering here is important:
      dp.Learn{
         learning_rate = opt.learningRate, 
         observer = dp.LearningRateSchedule{
            schedule = {[opt.decayPoint]=opt.learningRate*opt.decayFactor}
         }
      },
      dp.MaxNorm{max_out_norm = opt.maxOutNorm}
   },
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler{ --shuffle sample takes too much mem
      epoch_size = opt.trainEpochSize, batch_size = opt.batchSize
   },
   progress = true
}
valid = dp.Evaluator{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler{
      epoch_size = opt.validEpochSize, 
      batch_size = opt.softmaxtree and 1024 or opt.batchSize
   },
   progress = true
}
test = dp.Evaluator{
   loss = opt.softmaxtree and dp.TreeNLL() or dp.NLL(),
   feedback = dp.Perplexity(),  
   sampler = dp.Sampler{batch_size = opt.softmaxtree and 1024 or opt.batchSize}
}

--[[Experiment]]--
xp = dp.Experiment{
   model = mlp,
   optimizer = train,
   validator = valid,
   tester = test,
   observer = {
      dp.FileLogger(),
      dp.EarlyStopper{max_epochs = opt.maxTries}
   },
   random_seed = os.time(),
   max_epoch = opt.maxEpoch
}

xp:run(datasource)
