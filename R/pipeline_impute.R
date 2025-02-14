

#' @title Pirat imputation function
#' @description Imputation pipeline of Pirat. First, it creates PGs. Then,
#' it estimates parameters of the penalty term (that amounts to an
#' inverse-Wishart prior). Second, it estimates the missingness mechanism
#' parameters. Finally, it imputes the peptide/precursor-level dataset with 
#' desired extension.  
#'
#' @param data.pep.rna.mis A list containing important elements of the dataset 
#' to impute. Must contain:
#' **peptides_ab**, the peptide or precursor abundance matrix to impute, with 
#' samples in row and peptides or precursors in column; 
#' **adj**, a n_peptide x n_protein adjacency matrix between peptides and 
#' proteins containing 0 and 1, or TRUE and FALSE.
#' Can contain: 
#' **rnas_ab**, the mRNA normalized count matrix, with samples in 
#' row and mRNAs in column;
#' **adj_rna_pg**, a n_mrna x n_protein adjacency matrix n_mrna and proteins 
#' containing 0 and 1, or TRUE and FALSE; 
#' @param pep.ab.comp The pseudo-complete peptide or precursor abundance matrix,
#'  with samples in row and peptides or precursors in column. Useful only in 
#'  mask-and-impute experiments, if one wants to impute solely peptides 
#'  containing pseudo-MVs.
#' @param alpha.factor Factor that multiplies the parameter alpha of the 
#' penalty described in the original paper. 
#' @param rna.cond.mask Vector of indexes representing conditions of samples 
#' of mRNA table, only mandatory if extension == "T". For paired proteomic and 
#' transcriptomic tables, should be c(1:n_samples).
#' @param pep.cond.mask Vector of indexes representing conditions of samples 
#' of mRNA table, only mandatory if extension == "T". For paired proteomic 
#' and transcriptomic tables, should be c(1:n_samples).
#' @param extension If NULL (default), classical Pirat is applied. If "2", 
#' only imputes PGs containing at least 2 peptides or precursors, and 
#' remaining peptides are left unchanged.
#' If "S", Pirat-S is applied, considering sample-wise correlations only for
#'  singleton PGs.
#' It "T", Pirat-T is applied, thus requiring **rnas_ab** and **adj_rna_pg** 
#' in list **data.pep.rna.mis**, as well as non-NULL **rna.cond.mask** and 
#' **pep.cond.mask**.
#' Also, the maximum size of PGs for which transcriptomic data can be used is 
#' controlled with **max.pg.size.pirat.t**.
#' @param mcar If TRUE, forces gamma_1 = 0, thus no MNAR mechanism is 
#' considered.
#' @param degenerated If TRUE, applies Pirat-Degenerated (i.e. its univariate 
#' alternative) as described in original paper. Should not be TRUE unless for 
#' experimental purposes.
#' @param max.pg.size.pirat.t When extension == "T", the maximum PG size for 
#' which transcriptomic information is used for imputation. 
#' @param verbose A boolean (FALSE as default) which indicates whether to 
#' display more details on the process
#'
#' @import progress
#' @import MASS
#' @import invgamma
#' @import graphics
#'
#' @return The imputed **data.pep.rna.mis$peptides_ab** table.
#' @export
#' 
#' @name pipeline_llkimpute
#'
#' @examples
#' # Pirat classical mode
#' data(subbouyssie)
#' myResult <- my_pipeline_llkimpute(subbouyssie)
#' 
#' # Pirat with transcriptomic integration for singleton PGs
#' data(subropers)
#' nsamples = nrow(subropers$peptides_ab)
#' myResult <- my_pipeline_llkimpute(subropers, 
#' extension = "T",
#' rna.cond.mask = seq(nsamples), 
#' pep.cond.mask = seq(nsamples),
#' max.pg.size.pirat.t = 1)
#' 
#' \dontrun{
#' myResult <- pipeline_llkimpute(subbouyssie)
#' }
NULL




#' @rdname pipeline_llkimpute
#' 
#' @param data.pep.rna.mis Parameter 'data.pep.rna.mis' of the function 
#' `pipeline_llkimpute()`
#' @param ... Additional parameters for the function `pipeline_llkimpute()`
#' 
#' @seealso [pipeline_llkimpute()]
#' 
#' @export
#' 
#' @importFrom stats cov
#' 
#' @return The imputed **data.pep.rna.mis$peptides_ab** table.
#' 
#' @importFrom reticulate import
#' @importFrom basilisk basiliskStart basiliskRun basiliskStop
#' 
my_pipeline_llkimpute <- function(data.pep.rna.mis, ...) { 
    message('Starting Python environment...\n')
     proc <- basilisk::basiliskStart(envPirat)
    on.exit(basilisk::basiliskStop(proc))
    
    some_useful_thing <- basilisk::basiliskRun(proc, 
        fun = function(arg1, ...) {
            
            output <- pipeline_llkimpute(arg1, ...)
            # The return value MUST be a pure R object, i.e., no reticulate
            # Python objects, no pointers to shared memory. 
            output 
        }, arg1 = data.pep.rna.mis, ...)
    
    basilisk::basiliskStop(proc)
    some_useful_thing 
}


#' @rdname pipeline_llkimpute
#' @return NA
#' 
pipeline_llkimpute <- function(
    data.pep.rna.mis,
    pep.ab.comp = NULL,
    alpha.factor = 2,
    rna.cond.mask = NULL,
    pep.cond.mask = NULL,
    extension = c('base', '2', 'T', 'S'),
    mcar = FALSE,
    degenerated = FALSE,
    max.pg.size.pirat.t = 1,
    verbose = FALSE) {
  
    extension <- match.arg(extension)
    
    py <- reticulate::import("PyPirat")

  psi_rna = NULL
  
  if(verbose)
    message("extension: ", extension, "\n")
  
  if( verbose)
      message("Remove nested prots...")
  idx.emb.prots <- get_indexes_embedded_prots(data.pep.rna.mis$adj)
  data.pep.rna.mis <- rm_pg_from_idx_merge_pg(data.pep.rna.mis, idx.emb.prots)
  if( verbose)
      message("Data ready for boarding with Pirat")
  
  # Estimate Gamma distrib peptides
  obs2NApep <- data.pep.rna.mis$peptides_ab[
    ,colSums(is.na(data.pep.rna.mis$peptides_ab)) <= 0]

  est.psi.df <- estimate_psi_df(obs2NApep)
  df <- est.psi.df$df
  psi <- est.psi.df$psi
  
  if( verbose){
      message(paste(c("Estimated DF", df)))
      message(paste(c("Estimated psi", psi)))
  }
  
  # Estimate Gamma distrib RNA
  if (!is.null(rna.cond.mask)) {
    obs2NArna <- data.pep.rna.mis$rnas_ab[
      ,colSums(data.pep.rna.mis$rnas_ab == 0) <= 0]
    
    est.psi.df.rna <- estimate_psi_df(obs2NArna)
    if (is.null(est.psi.df.rna)) {
      psi_rna <- psi
    } else {
      psi_rna <- est.psi.df.rna$psi
    }
  }
  
  # Initial estimates of phi and phi0
  est.phi.phi0 <- estimate_gamma(data.pep.rna.mis$peptides_ab, mcar)
  gamma_1 <- est.phi.phi0$gamma_1
  gamma_0 <- est.phi.phi0$gamma_0
  nsamples <- nrow(data.pep.rna.mis$peptides_ab)
  
  
  if (extension == 'base' || extension == "2") { # No extension or 2 pep rule
    if (degenerated) { # Degenerated case (only for paper experiments)
      npep <- nrow(data.pep.rna.mis$adj)
      data.pep.rna.mis$adj <- matrix(as.logical(diag(npep)), npep)
    }
    if (extension == "2") {
      min.pg.size2imp <- 2
    } else if (extension == 'base') {
      min.pg.size2imp <- 1
    }

    res_per_block = impute_block_llk_reset(
        data.pep.rna.mis,
        psi = psi, 
        pep_ab_or = pep.ab.comp,
        df = df,
        nu_factor = alpha.factor,
        max_pg_size = 30,
        min.pg.size2imp = min.pg.size2imp,
        phi0 = gamma_0, 
        phi = gamma_1, 
        eps_chol = 1e-4, 
        eps_phi = 1e-5, 
        tol_obj = 1e-7, 
        tol_grad = 1e-5, 
        tol_param = 1e-4,
        maxiter = as.integer(5000), 
        lr = 0.5,
        phi_known = TRUE,
        max_try = 50, 
        max_ls = 500, 
        eps_sig = 1e-4, 
        nsamples = 1000,
        verbose = verbose)
    
    data.imputed <- impute_from_blocks(res_per_block, data.pep.rna.mis)
  }
  else if (extension == "S") { # Pirat-S
    res_per_block <- impute_block_llk_reset(
        data.pep.rna.mis,
        psi = psi, 
        df = df,
        pep_ab_or = pep.ab.comp,
        nu_factor = alpha.factor, 
        max_pg_size = 30, 
        min.pg.size2imp = 2,
        phi0 = gamma_0, 
        phi = gamma_1, 
        eps_chol = 1e-4, 
        eps_phi = 1e-5, 
        tol_obj = 1e-7, 
        tol_grad = 1e-5, 
        tol_param = 1e-4,
        maxiter = as.integer(5000), 
        lr = 0.5, 
        phi_known = TRUE,
        max_try = 50, 
        max_ls = 500, 
        eps_sig = 1e-4, 
        nsamples = 1000,
        verbose = verbose)
    
    data.imputed <- impute_from_blocks(res_per_block, data.pep.rna.mis)
    idx.pgs1 <- which(colSums(data.pep.rna.mis$adj) == 1)
    
    if (length(idx.pgs1) != 0) {
      .tmp <- data.pep.rna.mis$adj[, idx.pgs1, drop = FALSE]
      idx.pep.s1 <- which(rowSums(.tmp) >= 1)
      imputed.data.wo.s1 <- t(data.imputed[, -idx.pep.s1])
      peps1 <- t(data.pep.rna.mis$peptides_ab[, idx.pep.s1])
      cov.imputed <- stats::cov(imputed.data.wo.s1)
      mean.imputed <- colMeans(imputed.data.wo.s1)
      peps1.imputed <- py$impute_from_params(peps1, 
                                            mean.imputed, 
                                            cov.imputed, 
                                            0, 
                                            0)[[1]]
      data.imputed[, idx.pep.s1] <- t(peps1.imputed)
    }
  }
  else if (extension == "T") {
    if (is.null(data.pep.rna.mis$rnas_ab) | 
        is.null(data.pep.rna.mis$adj_rna_pg)) {
      stop("When using Pirat-T, data.pep.rna.mis must contain rnas_ab 
           and adj_rna_pg")
    }
    if (is.null(rna.cond.mask) | is.null(pep.cond.mask)) {
      stop("Experimental designed must be filled in rna.cond.mask and 
           pep.cond.mask when using Pirat-T")
    }
    isPG2imp.w.pirat <- max.pg.size.pirat.t + 1 <= 
      max(colSums(data.pep.rna.mis$adj))
    
    if (isPG2imp.w.pirat) {
      res_per_block_pirat <- impute_block_llk_reset(
        data.pep.rna.mis,
        psi = psi, 
        df = df,
        nu_factor = alpha.factor,
        max_pg_size = 30, 
        min.pg.size2imp = max.pg.size.pirat.t + 1,
        pep_ab_or = pep.ab.comp,
        phi0 = gamma_0, 
        phi = gamma_1, 
        eps_chol = 1e-4, 
        eps_phi = 1e-5, 
        tol_obj = 1e-7, 
        tol_grad = 1e-5, 
        tol_param = 1e-4,
        maxiter = as.integer(5000), 
        lr = 0.5, 
        phi_known = TRUE,
        max_try = 50, 
        max_ls = 500, 
        eps_sig = 1e-4, 
        nsamples = 1000,
        verbose = verbose)
      
      data.imputed.pirat <- impute_from_blocks(res_per_block_pirat, 
                                              data.pep.rna.mis)
    } 
    idx.pgs1 <- which(colSums(data.pep.rna.mis$adj) <= max.pg.size.pirat.t)
    if (length(idx.pgs1) != 0) {
      res_per_block_pirat_t <- impute_block_llk_reset_PG(
        data.pep.rna.mis,
        df = df,
        nu_factor = alpha.factor, 
        rna.cond.mask = rna.cond.mask,
        pep.cond.mask = pep.cond.mask,
        psi = psi, 
        psi_rna = psi_rna,
        max_pg_size = 30,
        pep_ab_or = pep.ab.comp, 
        max.pg.size2imp = max.pg.size.pirat.t, 
        phi0 = gamma_0, 
        phi = gamma_1, 
        eps_chol = 1e-4, 
        eps_phi = 1e-5, 
        tol_obj = 1e-7,
        tol_grad = 1e-5, 
        tol_param = 1e-4,
        maxiter = as.integer(5000), 
        lr = 0.5, 
        phi_known = TRUE,
        max_try = 50, 
        max_ls = 500, 
        eps_sig = 1e-4, 
        nsamples = 1000,
        verbose = verbose)
      
      data.imputed.pirat.t <- impute_from_blocks(res_per_block_pirat_t, 
                                                data.pep.rna.mis)
    }
    
    if (!isPG2imp.w.pirat) {
      data.imputed <- data.imputed.pirat.t
    } else if (length(idx.pgs1) == 0) {
      data.imputed <- data.imputed.pirat
    } else {
      combined <- array(c(data.imputed.pirat, data.imputed.pirat.t), 
                        dim = c(dim(data.imputed.pirat), 2))
      data.imputed <- apply(combined, c(1, 2), 
                            function(x) mean(x, na.rm = TRUE))
    }
  }
  colnames(data.imputed) <- colnames(data.pep.rna.mis$peptides_ab)
  rownames(data.imputed) <- rownames(data.pep.rna.mis$peptides_ab)
  #  Format results
  params = list(alpha = df/2,
                beta = psi/2,
                gamma0 = gamma_0,
                gamma1 = gamma_1)
  
  return(list(data.imputed = data.imputed,
              params = params)
  )
}
