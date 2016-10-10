
if (conf.load_old_network ~= true) then
  optimState = {
    learningRate = conf.learningRate,    
    learningRateDecay = 0.0,
    weightDecay = conf.weightDecay,
    momentum = conf.momentum, 
    nesterov = true,
    dampening = 0.0
  }
end


parameters,gradParameters = model:getParameters()

local batchNumber = 0
local numOfTrainImages = 0


local function paramsForEpoch(epoch)
    if conf.learningRate ~= 0.0 then -- if manually specified
        return { }
    end
    local regimes = {
        -- start, end,    LR,   WD,
        {  1,     12,   1e-3,   5e-4 },
        {13,     24,   1e-4,   5e-4  },
        { 17,     24,   1e-4,  5e-4 },
        { 25,     1e8,   1e-5,  5e-4 },
    }

    for _, row in ipairs(regimes) do
        if epoch >= row[1] and epoch <= row[2] then
            return { learningRate=row[3], weightDecay=row[4], shedule=regimes }, epoch == row[1]
        end
    end
end


function train()
  model:training()
  epoch = epoch or 1
  
  for i = 1, 7 do
    model.modules[i]:evaluate()
  end
  
  --model.modules[1]:evaluate()

  train_loss = 0
  batchNumber = 0
  
  if conf.learningRate == 0 then
     local params, newRegime = paramsForEpoch(epoch)
     if newRegime then
        optimState.learningRate = params.learningRate
        optimState.weightDecay = params.weightDecay
     end
     
     learning_rate_shedule = params.shedule
   end
   
  
  --[[
  if epoch % conf.epoch_step == 0 then 
    optimState.learningRate = optimState.learningRate * 0.1
  end]]--

  print(color.blue '==>'.." online epoch # " .. epoch .. ' [batchSize = ' .. conf.batch_size .. ']')
  
  local tic = torch.tic()
  
  local indices = torch.randperm(#image_roidb_train):long():split(conf.batch_size)
  
  -- remove last element if not full batch_size so that all the batches have equal size
  if (#image_roidb_train % conf.batch_size ~= 0) then
    indices[#indices] = nil
  end
  
  numOfTrainImages = #indices * conf.batch_size

  if #indices < conf.max_iter then
    epochL = #indices
  else
    epochL = conf.max_iter
  end

  cutorch.synchronize()

  
  for t,v in ipairs(indices) do
    -- queue jobs to data-workers
    --[[
    donkeys:addjob(
      -- the job callback (runs in data-worker thread)
      function() --load single batches
        local roidbs = generate_batch_roidbs(v, image_roidb_train)  
        local batch = proposal_generate_mini_batch(conf, roidbs)
        return batch
      end,
      -- the end callback (runs in the main thread)
      train_batch
    );
    ]]--
    
    local batch_roidbs = generate_batch_roidbs(v, image_roidb_train)  
    
    train_batch(batch_roidbs)
    
    if t == epochL then
      break
    end
  end

  cutorch.synchronize()

  train_loss = train_loss / epochL

  --train_loss = loss_epoch
  --train_fg_acc = acc_fg_epoch
  --train_bg_acc = acc_bg_epoch
  
  print(string.format('Epoch: [%d][TRAINING SUMMARY] Total Time(s): %.2f   loss:%.4f', epoch, torch.toc(tic), train_loss))
  print('\n')

  collectgarbage()

  if epoch % conf.save_epoch == 0 then
    if torch.type(model) == 'nn.DataParallelTable' then
      torch.save(paths.concat(conf.save_model_state, 'Models/model_' .. epoch .. '.t7'), model:get(1))
    else
      torch.save(paths.concat(conf.save_model_state, 'Models/model_' .. epoch .. '.t7'), model)
    end
    torch.save(paths.concat(conf.save_model_state, 'Models/optimState_' .. epoch .. '.t7'), optimState)
    local trainState = {}
    trainState.epoch = epoch
  end
  
end


local timer = torch.Timer()
local dataTimer = torch.Timer()


function train_batch(roidbs)

    cutorch.synchronize()
    collectgarbage()
    timer:reset()
    
    local train_batch = proposal_generate_mini_batch(conf, roidbs)
              
    local f = 0
    
    feval = function(x)
      collectgarbage()
                  
      if x ~= parameters then
        parameters:copy(x)
      end
      
      gradParameters:zero()
      
      local mini_batch = train_batch[1]:cuda()
      local output = model:forward(mini_batch)
      
      local n_cls = conf.rois_per_image
      local n_reg = 0
      
      for i = 1, #roidbs do
        -- get target
        local target_labels = train_batch[2][i]:cuda()
        local target_weights = train_batch[3][i]:cuda()
        local target_reg = train_batch[4][i]:cuda()
        local target_bbox_loss = train_batch[5][i]:cuda()
        
        n_reg = target_labels:size(1) * target_labels:size(2)
                     
        -- batch x (height x width) x boxes
        target_labels = target_labels:reshape(1, target_labels:size(2), target_labels:size(3))
        
        -- set neutral and negative bbox to zero
        local size = target_reg:size()
        target_reg[torch.ne(target_bbox_loss,1)] = 0
        target_reg:resize(size)
        
        -- transform output to target size
        --(heightx width) x boxes x 3 classes
        y_labels = output[1][i]:permute(2,3,1):cuda()
        y_labels = y_labels:reshape(1, y_labels:size(1)*y_labels:size(2), y_labels:size(3) / 3, 3)
        
        -- batch x classes x (height x widht) x boxes
        y_labels = y_labels:permute(1,4,2,3)
        
        -- number of anchor configurations ( ratios * scales)
        k = conf.total_anchors
        y_reg = output[2][i]:permute(2,3,1)
        y_reg = y_reg:reshape(y_reg:size(1)*y_reg:size(2)*k, 4)
        y_reg[torch.ne(target_bbox_loss,1)] = 0
        y_reg:resize(size)
        
        collectgarbage()
        y = {}
        
        -- only use positive and negative anchors for loss function
        table.insert(y, y_labels:contiguous())
        table.insert(y, y_reg)
        
        target = {}
        table.insert(target, target_labels:contiguous())
        table.insert(target, target_reg)
        
        -- Calc/add error
        f = f + conf.weight_l1crit *sl1:forward(y[2], target[2])/n_reg + conf.weight_scec * log:forward(y[1], target[1]) /n_cls
        
        -- f = f* (i-1)/i+ err*(1/i)
        local loss = criterion:forward(y, target)
        
        grad_list = criterion:backward(y, target)
        --table.insert(grad_list, log:backward(y[1], target[1]) * conf.weight_l1crit)
        --table.insert(grad_list, sl1:backward(y[2], target[2]) * conf.weight_scec)
        
        -- transform gradients back to correct dimension size 
               
        grad_list[1] = grad_list[1][1]:permute(2,3,1):cuda()
        grad_list[1] = grad_list[1]:reshape(output[1][i]:size(2), output[1][i]:size(3), output[1][i]:size(1))
        grad_list[1] = grad_list[1]:permute(3,1,2)
        grad_list[1]:div(n_cls)
        grad_list[2] = grad_list[2]:reshape(output[2][i]:size(2), output[2][i]:size(3), output[2][i]:size(1))
        grad_list[2] = grad_list[2]:permute(3,1,2)
        grad_list[2]:div(n_reg)
           
      end
    
      model:backward(mini_batch, grad_list)   
      
      f = f/ #roidbs

      return f, gradParameters--:div(opt.batchSize) --------------------------------------------------
  end
            
  optim.sgd(feval, parameters, optimState)   
  
  --print('Different Parameters:')
  --print(parameters:eq(temp):size())
  
  assert(parameters:storage() == model:parameters()[1]:storage())
  
  if model.needsSync then
    model:syncParameters()
  end
  
  cutorch.synchronize()
  
  batchNumber = batchNumber + 1
  
  train_loss = train_loss + f
  
  print(('Epoch: [%d][%d/%d]\tTime(s) %.3f  loss %.4f  LR %.0e'):format(
      epoch, batchNumber, math.floor(numOfTrainImages/conf.batch_size), timer:time().real, f, 
      optimState.learningRate))

end
  
