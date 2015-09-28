# This is to replicate the language modeling experiments from Zaremba,
# Wojciech, Ilya Sutskever, and Oriol Vinyals. "Recurrent neural
# network regularization." arXiv preprint arXiv:1409.2329 (2014).
#
# Usage: julia zaremba14.jl ptb.train.txt ptb.valid.txt ptb.test.txt
# Type julia zaremba14.jl --help for more options

using KUnet, ArgParse
import Base: start, next, done

function main(args=ARGS)
    opts = parse_commandline(args)
    println(opts)
    opts["seed"] > 0 && setseed(opts["seed"])
    dict = Dict{Any,Int32}()
    data = Any[]
    for f in opts["datafiles"]
        push!(data, LMData(f;  batch=opts["batch_size"], seqlen=opts["seq_length"], dict=dict))
    end
    vocab_size = length(dict)
    lstms = Any[]
    for i=1:opts["layers"]; push!(lstms, LSTM(opts["rnn_size"]; dropout=opts["dropout"])); end
    net = Net(Mmul(opts["rnn_size"]), lstms..., Mmul(vocab_size), Bias(), Soft(), SoftLoss())
    lr = opts["lr"]
    setparam!(net, lr=lr, init=rand!, initp=(-opts["init_weight"], opts["init_weight"]))
    perp = zeros(length(data))
    wmax = gmax = 0
    for ep=1:opts["max_max_epoch"]
        ep > opts["max_epoch"] && (lr /= opts["decay"]; setparam!(net, lr=lr))
        @date (ltrn,wmax,gmax) = train(net, data[1]; gclip=opts["max_grad_norm"], gcheck=opts["gcheck"], keepstate=true)
        perp[1] = exp(ltrn/data[1].seqlength)
        for idata = 2:length(data)
            @date ldev = test(net, data[idata]; keepstate=true)
            perp[idata] = exp(ldev/data[idata].seqlength) # TODO: look into reporting loss per sequence rather than per token
        end
        @show (ep, perp..., wmax, gmax, lr)
    end
end

type LMData; data; dict; batchsize; seqlength; batch; end

function LMData(fname::String; batch=batch_size, seqlen=seq_length, dict=Dict{Any,Int32}())
    data = Int32[]
    f = open(fname)
    for l in eachline(f)
        for w in split(l)
            push!(data, get!(dict, w, 1+length(dict)))
        end
        push!(data, get!(dict, "<eos>", 1+length(dict))) # end-of-sentence
    end
    x = [ speye(Float64, length(dict), batch) for i=1:seqlen+1 ]
    info("Read $fname: $(length(data)) words, $(length(dict)) vocab.")
    LMData(data, dict, batch, seqlen, x)
end

function start(d::LMData)
    mx = size(d.batch[1], 1)
    nd = length(d.dict)
    if nd > mx                  # if dict size increases, adjust batch arrays
        for x in d.batch; x.m = nd; end
    elseif nd  < mx
        error("Dictionary shrinkage")
    end
    return 0
end

function done(d::LMData,nword)
    # nword is the number of sequences served
    # stop if there is not enough data for another batch
    nword + d.batchsize * d.seqlength > length(d.data)
end

function next(d::LMData,nword)                              # d.data is the whole corpus represented as a sequence of Int32's
    segsize = div(length(d.data), d.batchsize)          # we split it into d.batchsize roughly equal sized segments
    offset = div(nword, d.batchsize) # this is how many words have been served so far from each segment
    for b = 1:d.batchsize
        idata = (b-1)*segsize + offset                  # start producing words in segment b at x=data[idata], y=data[idata+1]
        for t = 1:d.seqlength+1
            d.batch[t].rowval[b] = d.data[idata+t]
        end
    end
    xbatch = d.batch[1:d.seqlength]
    ybatch = d.batch[2:d.seqlength+1]
    ((xbatch, ybatch), nword + d.seqlength * d.batchsize)	# each call to next will deliver d.seqlength words from each of the d.batchsize segments
end

function parse_commandline(args)
    s = ArgParseSettings()
    @add_arg_table s begin
        "--batch_size"
        help = "minibatch size"
        arg_type = Int
        default = 20
        "--seq_length"
        help = "length of the input sequence"
        arg_type = Int
        default = 20
        "--layers"
        help = "number of lstm layers"
        arg_type = Int
        default = 2
        "--decay"
        help = "divide learning rate by this every epoch after max_epoch"
        arg_type = Float64
        default = 2.0
        "--rnn_size"
        help = "size of the lstm"
        arg_type = Int
        default = 200
        "--dropout"
        help = "dropout units with this probability"
        arg_type = Float64
        default =  0.0
        "--init_weight"
        help = "initialize weights uniformly in [-init_weight,init_weight]"
        arg_type = Float64
        default =  0.1
        "--lr"
        help = "learning rate"
        arg_type = Float64
        default = 1.0
        "--vocab_size"
        help = "size of the vocabulary"
        arg_type = Int
        default = 10000
        "--max_epoch"
        help = "number of epochs at initial lr"
        arg_type = Int
        default = 4
        "--max_max_epoch"
        help = "number of epochs to train"
        arg_type = Int
        default = 13
        "--max_grad_norm"
        help = "gradient clip"
        arg_type = Float64
        default = 5.0
        "--gcheck"
        help = "gradient check this many units per layer"
        arg_type = Int
        default = 0
        "--seed"
        help = "random seed, use 0 to turn off"
        arg_type = Int
        default = 42
        "--preset"
        help = "load one of the preset option combinations"
        arg_type = Int
        default = 0
        "datafiles"
        help = "corpus files: first one will be used for training"
        nargs = '+'
        required = true
    end
    opts = parse_args(args,s)
    # Parameters from the Zaremba implementation:
    if opts["preset"] == 1      # Trains 1h and gives test 115 perplexity.
        opts["batch_size"]=20
        opts["seq_length"]=20
        opts["layers"]=2
        opts["decay"]=2
        opts["rnn_size"]=200
        opts["dropout"]=0
        opts["init_weight"]=0.1
        opts["lr"]=1
        opts["vocab_size"]=10000
        opts["max_epoch"]=4
        opts["max_max_epoch"]=13
        opts["max_grad_norm"]=5
    elseif opts["preset"] == 2  # Train 1 day and gives 82 perplexity.
        opts["batch_size"]=20
        opts["seq_length"]=35
        opts["layers"]=2
        opts["decay"]=1.15
        opts["rnn_size"]=1500
        opts["dropout"]=0.65
        opts["init_weight"]=0.04
        opts["lr"]=1
        opts["vocab_size"]=10000
        opts["max_epoch"]=14
        opts["max_max_epoch"]=55
        opts["max_grad_norm"]=10
    end
    return opts
end

main()


### SAMPLE RUN:
# julia zaremba14.jl --preset 1 data/ptb.valid.txt data/ptb.test.txt 
# WARNING: requiring "Options" did not define a corresponding module.
# Dict{AbstractString,Any}("rnn_size"=>200,"lr"=>1,"decay"=>2,"batch_size"=>20,"dropout"=>0,"max_grad_norm"=>5,"preset"=>1,"max_epoch"=>4,"init_weight"=>0.1,"gcheck"=>0,"layers"=>2,"vocab_size"=>10000,"seq_length"=>20,"seed"=>42,"max_max_epoch"=>13,"datafiles"=>Any["data/ptb.valid.txt","data/ptb.test.txt"])
# INFO: Read data/ptb.valid.txt: 73760 words, 6022 vocab.
# INFO: Read data/ptb.test.txt: 82430 words, 7596 vocab.
#  37.057684 seconds (29.17 M allocations: 2.530 GB, 1.31% gc time)
#   9.723167 seconds (11.06 M allocations: 496.906 MB, 1.30% gc time)
# (ep,perp...,wmax,gmax,lr) = (1,964.7574812581911,680.8404134165187,359.66156655473776,182.60932042613925,1)
#  32.492913 seconds (24.07 M allocations: 2.306 GB, 1.39% gc time)
#   9.682416 seconds (11.04 M allocations: 496.187 MB, 1.23% gc time)
# (ep,perp...,wmax,gmax,lr) = (2,533.9658674987758,500.7701607049704,376.4021748281246,29.527137764770796,1)
#  32.433211 seconds (24.07 M allocations: 2.306 GB, 1.39% gc time)
#   9.759406 seconds (11.05 M allocations: 496.439 MB, 1.30% gc time)
# (ep,perp...,wmax,gmax,lr) = (3,390.1504382596744,435.37182169855157,390.84524322483344,30.692745370555468,1)