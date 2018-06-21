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
rstan_options(auto_write = TRUE)
options(mc.cores = parallel::detectCores())


outdir <- '/raid1/home/micro/mcmindsr/ryan/github_repos/stan_models/cophylogeny/gcmp_shipment_1_endos/output/2018-06-20_12-24-15'

load(file=file.path(outdir,'setup.RData'))
load(file=file.path(outdir,'fit.RData'))
##

## summarize the results separately for each sampled host tree
for(i in 1:NTrees) {
    
    check_hmc_diagnostics(fit[[i]])

    currplotdir <- file.path(outdir,paste0('tree_',i),'plots')
    currtabledir <- file.path(outdir,paste0('tree_',i),'tables')
    currdatadir <- file.path(outdir,paste0('tree_',i),'data')

    dir.create(currplotdir, recursive=T)
    dir.create(currtabledir, recursive=T)
    dir.create(currdatadir, recursive=T)

    ## plot the sampled tree with the time bins marked
    pdf(file=file.path(currplotdir,'sampledTree.pdf'), width=25, height=15)
    plot(hostTreesSampled[[i]],cex=0.75)
    for(age in max(nodeHeights(hostTreesSampled[[i]])) - meanBoundaries) {
        lines(x = c(age, age), y = c(1, length(hostTreesSampled[[i]]$tip.label)), lwd=1)
    }
    graphics.off()
    ##

    ## variance partitioning
    stDProps <- extract(fit[[i]], pars='stDProps')[[1]]
    colnames(stDProps) <- c(paste0('ADiv.',colnames(factLevelMat)), paste0('Specificity.',colnames(factLevelMat)), 'ADiv.host', 'host.specificity', 'microbe.prevalence')

    pdf(file=file.path(currplotdir,'scalesboxes.pdf'), width=25, height=15)
    boxplot(stDProps, cex.axis=0.5, las=2)
    graphics.off()

    save(stDProps,file=file.path(currdatadir,'stDProps.RData'))
    ##
    
    ## alpha diversity
    scaledAlphaDivEffects <- extract(fit[[i]], pars='scaledAlphaDivEffects')[[1]]
    save(scaledAlphaDivEffects,file=file.path(currdatadir,'scaledAlphaDivEffects.RData'))
    ##
    
    ## proportion of variance explained by each time bin
    metaVarProps <- extract(fit[[i]], pars='metaVarProps')[[1]]
    colnames(metaVarProps) <- c('prevalence','adiv','specificty')
    pdf(file=file.path(currplotdir,'metaVarProps_boxes.pdf'), width=25, height=15)
    boxplot(metaVarProps, cex.axis=0.5, las=2)
    graphics.off()
    save(metaVarProps,file=file.path(currdatadir,'metaVarProps.RData'))
    ##
    
    ## compare rates of host evolution in each time bin
    relativeEvolRates <- extract(fit[[i]], pars='relativeEvolRates')[[1]]
    colnames(relativeEvolRates) <- c(paste0('before ',meanBoundariesRounded[1],' mya'), paste0(meanBoundariesRounded[1],' - ',meanBoundariesRounded[2],' mya'), paste0(meanBoundariesRounded[2],' - ',meanBoundariesRounded[3],' mya'), paste0(meanBoundariesRounded[3],' - present'))

    pdf(file=file.path(currplotdir,'evolRatesRelToWeightedMean.pdf'), width=25, height=15)
    boxplot(relativeEvolRates, xlab='Time Period', ylab='Rate of Evolution Relative to Weighted Mean')
    graphics.off()

	save(relativeEvolRates,file=file.path(currdatadir,'relativeEvolRates.RData'))
    
    ## summarize effects
    currsubtabledir <- file.path(currtabledir, 'nodeEffects')
    dir.create(currsubtabledir, recursive=T)

    scaledMicrobeNodeEffects <- array(extract(fit[[i]], pars='scaledMicrobeNodeEffects', permuted=F, inc_warmup=T),
                                      dim=c(NMCSamples,
                                            NChains,
                                            NEffects + NHostNodes + 1,
                                            NMicrobeNodes),
                                      dimnames=list(sample  = NULL,
                                                    chain   = NULL,
                                                    effect  = c('microbePrevalence', colnames(modelMat)[1:NEffects], colnames(hostAncestors[[i]])),
                                                    taxnode = colnames(microbeAncestors)))
                                                    
    save(scaledMicrobeNodeEffects, file = file.path(currdatadir, 'scaledMicrobeNodeEffects.RData'))
                                                    
    baseLevelEffects <- array(NA,
                              dim=c(NMCSamples,
                                    NChains,
                                    length(sumconts),
                                    NMicrobeNodes),
                              dimnames=list(sample  = NULL,
                                            chain   = NULL,
                                            effect  = sumconts,
                                            taxnode = colnames(microbeAncestors)))
    for(j in 1:NMCSamples) {
        for(k in 1:NChains) {
            for(m in sumconts) {
                baseLevelEffects[j,k,m,] <- -colSums(scaledMicrobeNodeEffects[j,k,rownames(factLevelMat)[factLevelMat[,m]==1],])
            }
        }
    }
    
    save(baseLevelEffects, file = file.path(currdatadir, 'baseLevelEffects.RData'))

    for(l in 1:(NEffects + NHostNodes + 1)) {
        yeah <- monitor(array(scaledMicrobeNodeEffects[,,l,],
                              dim = c(NMCSamples, NChains, NMicrobeNodes)),
                        warmup = warmup,
                        probs = c(0.05, 0.95))
        rownames(yeah) <- rownames(microbeAncestors)
        cat('\t', file = file.path(currsubtabledir, paste0(dimnames(scaledMicrobeNodeEffects)[[3]][l], '.txt')))
        write.table(yeah, file = file.path(currsubtabledir, paste0(dimnames(scaledMicrobeNodeEffects)[[3]][l], '.txt')), sep='\t', quote=F,append=T)
    }
    
    for(m in sumconts) {
        yeah <- monitor(array(baseLevelEffects[,,m,],
                              dim = c(NMCSamples, NChains, NMicrobeNodes)),
                        warmup = warmup,
                        probs = c(0.05, 0.95))
        rownames(yeah) <- rownames(microbeAncestors)
        cat('\t', file = file.path(currsubtabledir, paste0(m, levels(newermap[,m])[nlevels(newermap[,m])], '.txt')))
        write.table(yeah, file = file.path(currsubtabledir, paste0(m, levels(newermap[,m])[nlevels(newermap[,m])], '.txt')), sep='\t', quote=F,append=T)
    }
    ##
    
    ## see if any pairs of clades have higher variance among their descendants (maybe suggesting codiversification)
    currsubtabledir <- file.path(currtabledir, 'codivEffects')
    dir.create(currsubtabledir, recursive=T)
    
    sums <- summary(fit[[i]], pars='phyloLogVarMultRaw', probs=c(0.05,0.95), use_cache = F)

    sums3d <- array(NA, dim=c(NHostNodes - NHostTips, NMicrobeNodes - NMicrobeTips, ncol(sums$summary)))
    for(effect in 1:(NHostNodes - NHostTips)) {
        sums3d[effect,,] <- sums$summary[(effect-1) * (NMicrobeNodes - NMicrobeTips) + (1:(NMicrobeNodes - NMicrobeTips)),]
    }
    dimnames(sums3d) <- list(colnames(hostAncestors[[i]])[(NHostTips + 1):NHostNodes], rownames(microbeAncestors)[(NMicrobeTips + 1):NMicrobeNodes], colnames(sums$summary))
    factorfilenames <- colnames(hostAncestors[[i]])[(NHostTips + 1):NHostNodes]

    for(effect in 1:(NHostNodes - NHostTips)) {
        cat('\t', file=file.path(currsubtabledir, paste0(factorfilenames[[effect]],'.txt')))
        write.table(sums3d[effect,,], file=file.path(currsubtabledir, paste0(factorfilenames[[effect]],'.txt')), sep='\t', quote=F,append=T)
    }
    ##
    
    ## summarize the mean branch lengths of the hosts
    sums <- summary(fit[[i]], pars='hostScales', probs=c(0.05,0.95), use_cache = F)
    newEdges <- sums$summary[,'mean']^2
    hostTreesSampled[[i]]$edge.length <- newEdges[order(hostEdgeOrder[[i]])]
    pdf(file=file.path(currplotdir,'hostTreeWEstimatedEdgeLengths.pdf'), width=25, height=15)
    plot(hostTreesSampled[[i]], cex=0.5)
    graphics.off()
    ##
}
##

## summarize results for parameters that can be interpretted across all sampled host trees
currplotdir <- file.path(outdir,'alltrees','plots')
currtabledir <- file.path(outdir,'alltrees','tables')
currdatadir <- file.path(outdir,'alltrees','data')

dir.create(currplotdir, recursive=T)
dir.create(currtabledir, recursive=T)
dir.create(currdatadir, recursive=T)

allfit <- sflist2stanfit(fit)

stDProps <- extract(allfit, pars='stDProps')[[1]]
colnames(stDProps) <- c(paste0('ADiv.',colnames(factLevelMat)), paste0('Specificity.',colnames(factLevelMat)), 'ADiv.host', 'host.specificity', 'microbe.prevalence')

pdf(file=file.path(currplotdir,'scalesboxes.pdf'), width=25, height=15)
boxplot(stDProps, cex.axis=0.5, las=2)
graphics.off()

save(stDProps,file=file.path(currdatadir,'stDProps.RData'))

relativeEvolRates <- extract(allfit, pars='relativeEvolRates')[[1]]
colnames(relativeEvolRates) <- c(paste0('before ',meanBoundariesRounded[1],' mya'), paste0(meanBoundariesRounded[1],' - ',meanBoundariesRounded[2],' mya'), paste0(meanBoundariesRounded[2],' - ',meanBoundariesRounded[3],' mya'), paste0(meanBoundariesRounded[3],' - present'))

pdf(file=file.path(currplotdir,'evolRatesRelToWeightedMean.pdf'), width=25, height=15)
boxplot(relativeEvolRates, xlab='Time Period', ylab='Rate of Evolution Relative to Weighted Mean')
graphics.off()

save(relativeEvolRates,file=file.path(currdatadir,'relativeEvolRates.RData'))

## summarize the mean branch lengths of the microbes
sums <- summary(allfit, pars='microbeScales', probs=c(0.05,0.95), use_cache = F)
newEdges <- sums$summary[,'mean']^2
microbeTree.Y.root$edge.length <- newEdges[order(microbeEdgeOrder)]
pdf(file=file.path(currplotdir,'microbeTreeWEstimatedEdgeLengths.pdf'), width=25, height=15)
plot(microbeTree.Y.root, cex=0.5)
graphics.off()
##

## summarize effects
currsubtabledir <- file.path(currtabledir, 'nodeEffects')
dir.create(currsubtabledir, recursive=T)

scaledMicrobeNodeEffects <- array(extract(allfit, pars='scaledMicrobeNodeEffects', permuted=F, inc_warmup=T),
                                  dim=c(NMCSamples,
                                        NChains * NTrees,
                                        NEffects + NHostNodes + 1,
                                        NMicrobeNodes),
                                  dimnames=list(sample  = NULL,
                                                chain   = NULL,
                                                effect  = c('microbePrevalence', colnames(modelMat)[1:NEffects], colnames(hostAncestors[[i]])),
                                                taxnode = colnames(microbeAncestors)))
                                                
save(scaledMicrobeNodeEffects, file = file.path(currdatadir, 'scaledMicrobeNodeEffects.RData'))
                                                
baseLevelEffects <- array(NA,
                          dim=c(NMCSamples,
                                NChains * NTrees,
                                length(sumconts),
                                NMicrobeNodes),
                          dimnames=list(sample  = NULL,
                                        chain   = NULL,
                                        effect  = sumconts,
                                        taxnode = colnames(microbeAncestors)))
for(j in 1:NMCSamples) {
    for(k in 1:(NChains * NTrees)) {
        for(m in sumconts) {
            baseLevelEffects[j,k,m,] <- -colSums(scaledMicrobeNodeEffects[j,k,rownames(factLevelMat)[factLevelMat[,m]==1],])
        }
    }
}

save(baseLevelEffects, file = file.path(currdatadir, 'baseLevelEffects.RData'))

for(l in 1:(NEffects + NHostNodes + 1)) {
    yeah <- monitor(array(scaledMicrobeNodeEffects[,,l,],
                          dim = c(NMCSamples, NChains * NTrees, NMicrobeNodes)),
                    warmup = warmup,
                    probs = c(0.05, 0.95))
    rownames(yeah) <- rownames(microbeAncestors)
    cat('\t', file = file.path(currsubtabledir, paste0(dimnames(scaledMicrobeNodeEffects)[[3]][l], '.txt')))
    write.table(yeah, file = file.path(currsubtabledir, paste0(dimnames(scaledMicrobeNodeEffects)[[3]][l], '.txt')), sep='\t', quote=F,append=T)
}

for(m in sumconts) {
    yeah <- monitor(array(baseLevelEffects[,,m,],
                          dim = c(NMCSamples, NChains * NTrees, NMicrobeNodes)),
                    warmup = warmup,
                    probs = c(0.05, 0.95))
    rownames(yeah) <- rownames(microbeAncestors)
    cat('\t', file = file.path(currsubtabledir, paste0(m, levels(newermap[,m])[nlevels(newermap[,m])], '.txt')))
    write.table(yeah, file = file.path(currsubtabledir, paste0(m, levels(newermap[,m])[nlevels(newermap[,m])], '.txt')), sep='\t', quote=F,append=T)
}
##


## fin
