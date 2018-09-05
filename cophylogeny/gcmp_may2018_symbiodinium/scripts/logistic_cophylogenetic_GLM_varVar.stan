functions {
    vector rescaleOU(matrix nhs, real alpha) {
        return (exp(-2.0 * alpha * (1 - nhs[,2]))
                - exp(-2.0 * alpha * (1 - nhs[,1])))
               ./ (nhs[,2] - nhs[,1]);
    }
}
data {
    int NSamples;
    int NObs;
    int NMicrobeNodes;
    int NMicrobeTips;
    int NMicrobeTimeBins;
    int NFactors;
    int NEffects;
    int NHostNodes;
    int NHostTips;
    int NHostTimeBins;
    int present[NObs];
    int sampleNames[NObs];
    int microbeTipNames[NObs];
    real<lower=0> aveStDPriorExpect;
    real<lower=0> aveStDMetaPriorExpect;
    real<lower=0> hostOUAlphaPriorExpect;
    real<lower=0> microbeOUAlphaPriorExpect;
    matrix[NEffects, NFactors] factLevelMat;
    matrix[NSamples, NEffects + NHostNodes + 1] modelMat;
    matrix[NMicrobeNodes, NMicrobeNodes] microbeAncestorsT;
    matrix[NMicrobeNodes + 1, NMicrobeTips] microbeTipAncestorsT;
    matrix[NHostNodes, NHostNodes] hostAncestors;
    matrix[NHostTips, NHostNodes] hostTipAncestors;
    matrix[NHostNodes, 2] hostNodeHeights;
    matrix[NMicrobeNodes, 2] microbeNodeHeights;
    matrix<lower=0>[NHostNodes, NHostTimeBins] hostEdgeToBin;
    matrix<lower=0>[NMicrobeTimeBins, NMicrobeNodes] microbeEdgeToBin;
    real<lower=0> globalScale;
}
parameters {
    real<lower=0> aveStD;
    simplex[2 * NFactors + 3] stDProps;
    real<lower=0> hostOUAlpha;
    real<lower=0> microbeOUAlpha;
    row_vector[NMicrobeTimeBins - 1] microbeTimeBinMetaVar;
    vector[NHostTimeBins - 1] hostTimeBinMetaVar;
    real<lower=0> aveStDMeta;
    simplex[3] metaVarProps;
    simplex[2] hostMetaVarProps;
    simplex[2] microbeMetaVarProps;
    row_vector[NMicrobeNodes] phyloLogVarMultPrev;
    vector[NHostNodes] phyloLogVarMultADiv;
    matrix[NHostNodes, NMicrobeNodes] phyloLogVarMultRaw;
    matrix[NEffects + NHostNodes + 1, NMicrobeNodes + 1] rawMicrobeNodeEffects;
}
transformed parameters {
    vector<lower=0>[2 * NFactors + 3] scales;
    vector<lower=0>[3] metaScales;
    row_vector<lower=0>[NMicrobeNodes] microbeVarRaw;
    row_vector<lower=0>[NMicrobeNodes] microbeScales;
    row_vector[NMicrobeTimeBins] logRelativeMicrobeEvolRates;
    vector[NHostTimeBins] logRelativeHostEvolRates;
    vector<lower=0>[NHostNodes] hostVarRaw;
    vector<lower=0>[NHostNodes] hostScales;
    matrix<lower=0>[NHostNodes, NMicrobeNodes] phyloVarRaw;
    matrix<lower=0>[NHostNodes, NMicrobeNodes] phyloScales;
    matrix[NEffects + NHostNodes + 1, NMicrobeNodes + 1] scaledMicrobeNodeEffects;
    scales
        = sqrt((2 * NFactors + 3) * stDProps)
          * aveStD;
    metaScales
        = sqrt(3 * metaVarProps)
          * aveStDMeta;
    logRelativeMicrobeEvolRates[2:]
        = microbeTimeBinMetaVar
          * metaScales[1]
          * sqrt(microbeMetaVarProps[1]));
    logRelativeMicrobeEvolRates[1]
        = -sum(logRelativeMicrobeEvolRates[2:]);
    microbeVarRaw
        = rescaleOU(microbeNodeHeights, microbeOUAlpha)'
          .* (exp(logRelativeMicrobeEvolRates) * microbeEdgeToBin)
          .* exp((phyloLogVarMultPrev
                  * metaScales[1]
                  * sqrt(microbeMetaVarProps[2]))
                 * microbeAncestorsT);
    microbeScales
        = sqrt(microbeVarRaw
               / mean(microbeVarRaw * microbeTipAncestorsT[2:,]));
    logRelativeHostEvolRates[2:]
        = hostTimeBinMetaVar
          * metaScales[2]
          * sqrt(hostMetaVarProps[1]));
    logRelativeHostEvolRates[1]
        = -sum(logRelativeHostEvolRates[2:]);
    hostVarRaw
        = rescaleOU(hostNodeHeights, hostOUAlpha)
          .* (hostEdgeToBin * exp(logRelativeHostEvolRates))
          .* exp(hostAncestors
              * (phyloLogVarMultADiv
                 * metaScales[2]
                 * sqrt(hostMetaVarProps[2])));
    hostScales
        = scales[2 * NFactors + 1]
          * sqrt(hostVarRaw
                 / mean(hostTipAncestors * hostVarRaw));

    phyloVarRaw
        = exp(hostAncestors
              * (phyloLogVarMultRaw
                 * metaScales[3])
              * microbeAncestorsT)
          .* (hostVarRaw * microbeVarRaw);
    phyloScales
        = scales[2 * NFactors + 2]
          * sqrt(phyloVarRaw
                 / mean(hostTipAncestors
                        * (phyloVarRaw
                           * microbeTipAncestorsT[2:,])));
    scaledMicrobeNodeEffects
        = append_col(
                append_row(globalScale,
                           append_row(factLevelMat * segment(scales, 1, NFactors),
                                      hostScales)),
                append_row(
                    append_row(
                        scales[2 * NFactors + 3],
                        factLevelMat * segment(scales, NFactors + 1, NFactors))
                    * microbeScales,
                    phyloScales))
          .* rawMicrobeNodeEffects;
}
model {
    matrix[NSamples, NMicrobeTips] sampleTipEffects;
    vector[NObs] logit_ratios;
    aveStD ~ exponential(1.0 / aveStDPriorExpect);
    stDProps ~ dirichlet(rep_vector(1, 2 * NFactors + 3));
    hostOUAlpha ~ exponential(1.0 / hostOUAlphaPriorExpect);
    microbeOUAlpha ~ exponential(1.0 / microbeOUAlphaPriorExpect);
    hostTimeBinMetaVar ~ normal(0,1);
    microbeTimeBinMetaVar ~ normal(0,1);
    aveStDMeta ~ exponential(1.0 / aveStDMetaPriorExpect);
    metaVarProps ~ dirichlet(rep_vector(1, 3));
    hostMetaVarProps ~ dirichlet(rep_vector(1, 2));
    microbeMetaVarProps ~ dirichlet(rep_vector(1, 2));
    phyloLogVarMultPrev ~ normal(0,1);
    phyloLogVarMultADiv ~ normal(0,1);
    to_vector(phyloLogVarMultRaw) ~ normal(0,1);
    to_vector(rawMicrobeNodeEffects) ~ normal(0,1);
    sampleTipEffects = modelMat * (scaledMicrobeNodeEffects * microbeTipAncestorsT);
    for (n in 1:NObs)
        logit_ratios[n] = sampleTipEffects[sampleNames[n], microbeTipNames[n]];
    present ~ bernoulli_logit(logit_ratios);
}
