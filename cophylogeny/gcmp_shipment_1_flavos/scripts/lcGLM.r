library(ape)
library(phangorn)
library(geosphere)
library(rstan)
library(geiger)
library(phytools)
library(shinystan)
library(nlme)
library(reshape2)
library(paleotree)
library(parallel)
library(ggplot2)
library(RColorBrewer)
rstan_options(auto_write = TRUE)
options(mc.cores = parallel::detectCores())
source(file.path('scripts', 'lcGLM_functions.r'))


microbeTreePath <- 'raw_data/gg_constrained_fastttree.tre' #ML microbial phylogeny
hostTreePath <- 'raw_data/combined_trees.newick' #set of Bayesian draws of host species phylogeny
mapfilePath <- 'raw_data/GCMP_EMP_map_r28.txt' #mapping file
fulltablePath <- 'raw_data/reference-hit.txt' #250 bp deblur otu table output
taxAssignmentPath <- 'raw_data/reference-hit.seqs_tax_assignments.txt' #greegenes taxonomy
modelPath <- 'scripts/logistic_cophylogenetic_GLM_varVar.stan' #stan model
seed <- 123
timeLimit <- 30 * 24 * 60 * 60

outdir <- file.path('output',gsub(':', '-', gsub(' ', '_', Sys.time())))

## filtration options
minCountSamp <- 100 # minimum sequencing depth for a sample to be included
minPercent <- 0 # minimum percent of a sample composed of a sequence variant for it to pass the below filter
minSamps <- 1 # minimum number of samples that a sequence variant is present in at the above threshold for it to be included
##

## model options
aveStDPriorExpect <- 1.0
aveStDMetaPriorExpect <- 0.1
hostOUAlphaPriorExpect <- 1.0
microbeOUAlphaPriorExpect <- 1.0
stDLogitHostPriorExpect <- 0.1
stDLogitMicrobePriorExpect <- 0.1
globalScale <- 50
NTrees <- 1 ## number of random trees to sample and to fit the model to
modelform <- ~ ocean + ocean_area + reef_name + concatenated_date + colony_name + tissue_compartment + log_sequencing_depth_scaled
##

## Stan options
init_r <- 2
NCores <- 1
NChains <- 1 ## this is per tree; since I'm doing a large number of trees in parallel i'll just do one chain for each
NIterations <- 1500 ## will probably need >10,000? maybe start with 2, check convergence, double it, check, double, check, double, etc.?
max_treedepth <- 10 ## a warning will tell you if this needs to be increased
adapt_delta <- 0.8 ## increase this if you get 'divergences' - even one means your model fit sucks!
minMCSamples <- 2000 ## approximate number of Monte Carlo samples to save from the fit
##

## define the set of genera that we think our unidentified fungid samples could belong to
possibleFungidGenera <- c('Fungia_', 'Danafungia_', 'Cycloseris_', 'Pleuractis_')
## would be good here and for samples ID'd to genus to have some kind of weights for each possible species. i.e. it's really not possible that the acropora samples are A. cervicornis or palmata because their range is wrong, so even though I don't know which Acropora species exactly, I do have some info about the relative probabilities for many of them. similarly, some species might just be super rare in general and should likely be downweighted

taxaToExclude <- c('Aiptasia_sp','Entacmaea_quadricolor','Heteractis_aurora','Macrorhynchia_philippina','Mnemiopsis_sp','Sarcophyton_sp','Sinularia_polydactyla','Stichodactyla__gigantea','Xenia_umbellata') # don't currently have a way to incorporate these into the phylogeny...

sampleTipKey <- 'host_scientific_name'

filterfunction <- function(dfin) {
    levels(dfin[,sampleTipKey]) <- gsub(' ','_',levels(dfin[,sampleTipKey]))
    df2 <- droplevels(dfin[(dfin$tissue_compartment=='T' |
                            dfin$tissue_compartment=='S' |
                            dfin$tissue_compartment=='M') &
                            !grepl(paste(c('Unknown|Missing',
                                           taxaToExclude),
                                         collapse = '|'),
                                   dfin[,sampleTipKey],
                                   ignore.case = T),])
    return(df2)
}
    
contrastfunction <- function(dfin) {
    df2 <- dfin
    contrasts(df2$ocean) <- 'contr.sum'
    contrasts(df2$ocean_area) <- 'contr.sum'
    contrasts(df2$host_scientific_name) <- 'contr.sum'
    contrasts(df2$tissue_compartment) <- 'contr.sum'
    contrasts(df2$reef_name) <- 'contr.sum'
    contrasts(df2$concatenated_date) <- 'contr.sum'
    contrasts(df2$colony_name) <- 'contr.sum'
    levels(df2[,sampleTipKey])[levels(df2[,sampleTipKey]) == 'Homophyllia_hillae'] <- "Homophyllia_bowerbanki"
    levels(df2[,sampleTipKey])[levels(df2[,sampleTipKey]) == 'Pocillopora_eydouxi'] <- "Pocillopora_grandis"
    levels(df2[,sampleTipKey])[levels(df2[,sampleTipKey]) == 'Pseudosiderastrea_tayami'] <- "Pseudosiderastrea_tayamai"
    return(df2)
}

## import host phylogenies
hostTree <- read.tree(hostTreePath)
hostTree <- .compressTipLabel(hostTree)
##

## import mapping file
map <- read.table(mapfilePath, header = T, sep = '\t', comment.char = '', check.names = F)
rownames(map) <- map[,'#SampleID']
newmap <- filterfunction(map)
##

## import data; merge data and mapping file
fulltable <- t(read.table(fulltablePath, header = T, sep = '\t', skip = 1, comment.char = '', row.names = 1, check.names = F))
idx <- rownames(fulltable)[rownames(fulltable) %in% rownames(newmap) & rowSums(fulltable) >= minCountSamp]
y.old <- fulltable[idx, ]
newermaptemp <- droplevels(newmap[idx,])
##

## define contrasts
newermap <- contrastfunction(newermaptemp)
##

y.old.filt <- t(apply(y.old,1,function(x) {
    temp <- x/sum(x)
    return(temp > minPercent & !is.na(temp))
}))
y.old.binary <- apply(y.old,2,function(x) x > 0)
mode(y.old.binary) <- 'numeric'

y.binary.filtered <- y.old.binary[,colSums(y.old.filt) >= minSamps]


taxdat <- read.table(taxAssignmentPath, sep = '\t',stringsAsFactors = F, row.names = 1)
x <- strsplit(taxdat[, 1], '; ')
most <- max(sapply(x, length))
parsedtax <- lapply(x, function(x) {length(x) <- most; return(x)})
tax <- do.call('rbind', parsedtax)
rownames(tax) <- rownames(taxdat)
colnames(tax) <- c('Kingdom', 'Phylum', 'Class', 'Order', 'Family', 'Genus', 'Species')


subgroup <- rownames(tax[tax[,'Family'] == 'f__Flavobacteriaceae' & !is.na(tax[,'Family']),])
mySubgroup <- colnames(y.binary.filtered)[colnames(y.binary.filtered) %in% subgroup]

supergroup <- rownames(tax[tax[,'Order'] == 'o__Flavobacteriales' & !is.na(tax[,'Order']),])
mySupergroup <- colnames(y.binary.filtered)[colnames(y.binary.filtered) %in% supergroup]
mySupergroupSampled <- sample(mySupergroup[!mySupergroup %in% mySubgroup], ceiling(length(mySubgroup) / 20))

myOthersSampled <- sample(colnames(y.binary.filtered)[!colnames(y.binary.filtered) %in% c(mySubgroup, mySupergroup)], ceiling(length(mySubgroup) / 20))

y.binary.filtered.subset <- y.binary.filtered[,colnames(y.binary.filtered) %in% c(mySubgroup, mySupergroupSampled, myOthersSampled)]



## import microbe tree
microbeTree <- read.tree(microbeTreePath)
microbeTree.Y <- drop.tip(microbeTree, microbeTree$tip.label[!microbeTree$tip.label %in% colnames(y.binary.filtered.subset)])
##



## root the tree if it's unrooted
if(is.rooted(microbeTree.Y)) {
    finalMicrobeTree <- reorder(microbeTree.Y, order = 'pruningwise')
} else {
    finalMicrobeTree <- reorder(midpoint.root(microbeTree.Y), order = 'pruningwise')
}
##

## add edge lengths to microbial tree if they're missing, and make tips contemporary
if(is.null(finalMicrobeTree$edge.length)) {
    finalMicrobeTree$edge.length <- rep(1, length(finalMicrobeTree$edge))
    finalMicrobeTree <- chronos(finalMicrobeTree, control = chronos.control(tol = 1e-12)) #default tolerance of 1e-8 seems to lead to underflow and edge lengths of 0.
    class(finalMicrobeTree) <- 'phylo'
} else {
    finalMicrobeTree <- chronos(finalMicrobeTree, control = chronos.control(tol = 1e-12))
    class(finalMicrobeTree) <- 'phylo'
}
##


## summarize the putative taxa to be estimated
microbes <- factor(colnames(y.binary.filtered.subset), levels = finalMicrobeTree$tip.label)
microbeNames <- levels(microbes)
NMicrobeTips <- length(microbeNames)
##

## sort the OTU table so its entries match the tree's tip labels
y <- y.binary.filtered.subset[,microbeNames]
##

## generate some summary numbers regarding microbes
microbeTips <- colnames(y)
NMicrobeTips <- length(microbeTips)
NIntMicrobeNodes <- finalMicrobeTree$Nnode
NMicrobeNodes <- NMicrobeTips + NIntMicrobeNodes - 1
microbeTreeDetails <- getTreeDetails(finalMicrobeTree)
microbeEdges <- finalMicrobeTree$edge.length[microbeTreeDetails$edgeOrder]
##

## create ancestry matrix for microbes
microbeAncestors <- createAncestryMat(NMicrobeNodes,
                                      finalMicrobeTree,
                                      NMicrobeTips,
                                      microbeTips)
colnames(microbeAncestors)[1:NMicrobeTips] <- rownames(microbeAncestors)[1:NMicrobeTips] <- paste0('t', microbeTips)
##

## melt the data into long format to feed to model, and generate summary numbers about samples
senddat <- melt(y, varnames = c('sample', 'tip'), value.name = 'present')
sampleNames <- as.numeric(factor(senddat[,1]))
microbeTipNames <- as.numeric(factor(senddat[,2], levels = microbeTips))
present <- senddat[,3]
NObs <- nrow(senddat)
NSamples <- length(unique(sampleNames))
##

## make the mapping file match the set and order of samples in the data
newermap <- newermap[levels(factor(senddat[,1])),]
##

## prepare sequencing depth input
newermap$sequencing_depth <- rowSums(y.old[,microbeTips])
newermap$log_sequencing_depth <- log(newermap$sequencing_depth)
newermap$log_sequencing_depth_scaled <- scale(newermap$log_sequencing_depth)
##

## extract all the possible species that 'fungid' could refer to
possibleFungidSpecs <- grep(paste0(paste(possibleFungidGenera, collapse = '|'), '_'), attr(hostTree, "TipLabel"), value = T)
##

## identify unique Scleractinian species in the data, and replace spaces with underscores
study.species <- gsub(' ', '_', levels(newermap[,sampleTipKey]))
##

## identify the Scleractinian species in the data that do not exist in the template tree
study.species.missing <- study.species[!study.species %in% grep(paste(c(attr(hostTree, "TipLabel"),
                                                                        'Fungid',
                                                                        'not_applicable'),
                                                                      collapse = '|'),
                                                                study.species,
                                                                ignore.case = T,
                                                                value = T)]
generaOfUnknowns <- sapply(study.species.missing, function(x) strsplit(x, '_')[[1]][[1]])
##

### starting here, generate multiple random samples of the map and trees (later to be summarized to define the time Bins and also to be separately used for replicate runs of the model)
sampleMap <- list()
hostTreesSampled <- list()
hostTreeDetails <- list()
for(i in 1:NTrees) {
    sampleMap[[i]] <- newermap
    fungidSps <- grep('Fungid', levels(sampleMap[[i]][,sampleTipKey]))
    ##assign unidentified Fungids to a random member of the group independently for each tree
    levels(sampleMap[[i]][,sampleTipKey])[fungidSps] <- sample(possibleFungidSpecs[!possibleFungidSpecs %in% levels(sampleMap[[i]][,sampleTipKey])],
                                                        length(fungidSps))
    for (j in unique(generaOfUnknowns)) {
        possibleGenera <- attr(hostTree, "TipLabel")[!attr(hostTree, "TipLabel") %in% levels(sampleMap[[i]][,sampleTipKey])]
        if(!any(grepl(j, possibleGenera))) {
            possibleGenera <- attr(hostTree, "TipLabel")
        }
        ## assign unidentified species to a random member of their genus independently for each tree
        levels(sampleMap[[i]][,sampleTipKey])[levels(sampleMap[[i]][,sampleTipKey]) %in% grep(paste0(j, '_'),
                                                                                              study.species.missing,
                                                                                              value = T)] <- sample(grep(paste0(j, '_'),
                                                                                                                         possibleGenera,
                                                                                                                         value = T),
                                                                                                                    sum(generaOfUnknowns == j))
    }

    #filter the tree only contain the sampled (or assigned) species
    hostTreesSampled[[i]] <- ladderize(drop.tip(hostTree[[i]],hostTree[[i]]$tip.label[!hostTree[[i]]$tip.label %in% levels(sampleMap[[i]][,sampleTipKey])]))
    
    #get some tree stats for later use
    hostTreeDetails[[i]] <- getTreeDetails(hostTreesSampled[[i]])
}

## create ancestry matrices for each host tree
NHostTips <- length(hostTreesSampled[[1]]$tip.label)
NIntHostNodes <- hostTreesSampled[[1]]$Nnode
NHostNodes <- NIntHostNodes + NHostTips - 1
hostAncestors <- list()
hostAncestorsExpanded <- list()
for (i in 1:NTrees) {
    hostAncestors[[i]] <- createAncestryMat(NHostNodes,
                                            hostTreesSampled[[i]],
                                            NHostTips,
                                            hostTreesSampled[[i]]$tip.label)
    hostAncestorsExpanded[[i]] <- hostAncestors[[i]][as.character(sampleMap[[i]][,sampleTipKey]),]
    rownames(hostAncestorsExpanded[[i]]) <- rownames(sampleMap[[i]])
}
##

## prepare data for the model matrix
allfactors <- attr(terms.formula(modelform), "term.labels")
NFactors <- length(allfactors)
allfactorder <- sapply(allfactors, function(x) sum(gregexpr(':', x, fixed = TRUE)[[1]] > 0))
modelMat <- model.matrix(modelform, model.frame(newermap, na.action = NULL))
modelMat[is.na(modelMat)] <- 0
sumconts <- names(attr(modelMat, "contrasts")[attr(modelMat, "contrasts") == 'contr.sum'])
##

## create matrix relating each 'effect' (categorical and numeric) to the 'factor' that it belongs to
stDAdjust <- rep(1, NFactors)
baseLevelMat <- NULL
factLevelMat <- matrix(NA, nrow = ncol(modelMat) - 1, ncol = NFactors)
colnames(factLevelMat) <- c(allfactors)
NSumTo0 <- 0
for(j in 1:NFactors) {
    newColumn <- as.numeric(attr(modelMat, 'assign')[-1] == j)
    if(colnames(factLevelMat)[[j]] %in% names(attr(modelMat, "contrasts"))) {
        if(attr(modelMat, "contrasts")[[colnames(factLevelMat)[[j]]]] == 'contr.sum') {
            ## if the contrast is a sum-to-zero ('effects') contrast, adjust the scale in preparation for making symmetrical marginal priors
            stDAdjust[[j]] <- 1 / sqrt(1 - 1 / (sum(newColumn) + 1))
            baseLevelMat <- rbind(baseLevelMat, -newColumn)
            factLevelMat[,j] <- newColumn * stDAdjust[[j]]
            NSumTo0 <- NSumTo0 + 1
        } else {
            factLevelMat[,j] <- newColumn
        }
    } else {
        factLevelMat[,j] <- newColumn
    }
}

##
NEffects <- ncol(modelMat) - 1
##


## rename factors that have 'sum contrasts' because by default they get arbitrary names (careful with interpretation of interactions... probably better to add them as separate 'main effects' produced by concatenation)
for(j in sumconts) {
    searchTerms <- paste0('^', j, 1:(nlevels(newermap[,j]) - 1), '$')
    replacementTerms <- paste0(j, levels(newermap[,j])[-nlevels(newermap[,j])])
    for(k in 1:length(searchTerms)) {
        colnames(modelMat) <- sub(searchTerms[[k]], replacementTerms[[k]], colnames(modelMat))
    }
}
rownames(factLevelMat) <- colnames(modelMat)[2:ncol(modelMat)]
##

## collect data to feed to stan
standat <- list()
for (i in 1:NTrees) {
    standat[[i]] <- list(NSamples                       = NSamples,
                         NObs                           = NObs,
                         NMicrobeNodes                  = NMicrobeNodes,
                         NMicrobeTips                   = NMicrobeTips,
                         NFactors                       = NFactors,
                         NEffects                       = NEffects,
                         present                        = present,
                         sampleNames                    = sampleNames,
                         microbeTipNames                = microbeTipNames,
                         factLevelMat                   = factLevelMat,
                         modelMat                       = cbind(modelMat, hostAncestorsExpanded[[i]]),
                         NSumTo0                        = NSumTo0,
                         baseLevelMat                   = baseLevelMat,
                         microbeAncestorsT              = t(microbeAncestors),
                         microbeTipAncestorsT           = t(cbind(1, microbeAncestors[1:NMicrobeTips, ])),
                         hostAncestors                  = hostAncestors[[i]],
                         hostTipAncestors               = hostAncestors[[i]][1:NHostTips, ],
                         microbeParents                 = microbeTreeDetails$pm,
                         hostParents                    = hostTreeDetails[[i]]$pm,
                         hostLogitNH                    = hostTreeDetails[[i]]$logitNH,
                         microbeLogitNH                 = microbeTreeDetails$logitNH,
                         stDLogitHostPriorExpect        = stDLogitHostPriorExpect,
                         stDLogitMicrobePriorExpect     = stDLogitMicrobePriorExpect,
                         NHostNodes                     = NHostNodes,
                         aveStDPriorExpect              = aveStDPriorExpect,
                         aveStDMetaPriorExpect          = aveStDMetaPriorExpect,
                         hostOUAlphaPriorExpect         = hostOUAlphaPriorExpect,
                         microbeOUAlphaPriorExpect      = microbeOUAlphaPriorExpect,
                         globalScale                    = globalScale)
}

thin = max(1, floor(NIterations / minMCSamples))
NMCSamples <- NIterations / thin
warmup <- floor(NMCSamples / 2)
##

## run the model!
runStanModel()

## re-fit the model but ignore all data (sampling from prior to see if there are any biases generated by the model itself)
runStanModel(noData = T)

## re-fit the model but ignore shuffle the data (to see if there are any biases generated by the sampling design)
runStanModel(shuffleData = T)

## fin
