# multiclass
function predict(
    X::AbstractMatrix{T}, w::AbstractMatrix{T},
    H::AbstractArray{T, 3}, ind::AbstractVector{Int64}
) where T <: Real
    Xview = @view X[:, ind]
    K = size(w, 2)
    n = size(X, 1)
    A = Matrix{T}(undef, n, K)
    predict!(A, Xview, w, H)
    return A
end

function predict!(
    A::AbstractMatrix{T}, X::AbstractMatrix{T},
    w::AbstractMatrix{T}, H::AbstractArray{T, 3}#, ind::AbstractVector{Int64}
) where T <: Real
    #Xview = @view X[:, ind]
    n, d = size(X)
    K = size(w, 2)
    #@inbounds for k ∈ 1:K
    #    # p = view(A, :, k)
    #    # p .= diag(X * view(H, :, :, k) * Xt)
    #    A[:, k] .= (
    #        1 .+ π .* diag(X * view(H, :, :, k) * Xt) ./ 8
    #    ).^(-0.5) .* (X * view(w, :, k))
    #end
    ### using LoopVectorization
    fill!(A, 1.)
    LoopVectorization.@turbo for k ∈ 1:K
        for nn ∈ 1:n, i ∈ 1:d, j ∈ 1:d
            A[nn, k] += (π / 8) * X[nn, i] * H[i, j, k] * X[nn, j]
        end
    end
    A .= A.^(-0.5)
    A .*= X * w
    LoopVectorization.@avx A .= exp.(A) ./ sum(exp.(A), dims=2)
    return A
end

function RVM!(
    X::AbstractMatrix{T}, t::AbstractMatrix{T}, α::AbstractMatrix{T};
    rtol=1e-5, atol=1e-8, maxiter=100000
) where T<:Real
    # Multinomial
    n = size(X, 1)
    d = size(X, 2)
    size(t, 1) == n || throw(DimensionMismatch("Sizes of X and t mismatch."))
    size(α, 1) == d || throw(DimensionMismatch("Sizes of X and initial α mismatch."))
    K = size(t, 2)  # total number of classes
    size(α, 2) == K || throw(DimensionMismatch("Number of classes and size of α mismatch."))

    # initialise
    # preallocate type-II likelihood (evidence) vector
    llh2 = Vector{T}(undef, maxiter)
    fill!(llh2, -Inf)
    w = ones(T, d, K) * 0.00001
    #αp = ones(T, d, K)
    A, Y, logY = (Matrix{T}(undef, n, K) for _ = 1:3)
    for iter ∈ 2:maxiter
        ind = unique!([item[1] for item in findall(α .< 10000)])
        n_ind = size(ind, 1)
        αtmp = copy(α[ind, :])
        wtmp = copy(w[ind, :])
        Xtmp = copy(X[:, ind])
        #copyto!(αp, α)
        llh2[iter] = Logit!(
            wtmp, αtmp, Xtmp,
            t, atol, maxiter, A, Y, logY
        )
        w[ind, :] .= wtmp
        # update α
        @inbounds Threads.@threads for k ∈ 1:K
            # update alpha - what is y?
            #@views mul!(a, X, wtmp[:, k])
            #y .= 1.0 ./ (1.0 .+ exp.(-1.0 .* a))
            α2 = view(αtmp, :, k)
            yk = view(Y, :, k)
            WoodburyInv!(
                α2, α[ind, k],
                Diagonal(sqrt.(yk .* (1 .- yk))) * Xtmp
            )
            α[ind, k] .= (1 .- α[ind, k] .* α2) ./ view(wtmp, :, k).^2
        end
        #@info "α" α[ind, :]
        # check convergence
        incr = abs((llh2[iter] - llh2[iter-1]) / llh2[iter-1])
        @info "iteration $iter" incr
        if incr < rtol
            H = Array{T}(undef, n_ind, n_ind, K)
            @inbounds Threads.@threads for k ∈ 1:K
                yk = view(Y, :, k)
                H[:, :, k] .= WoodburyInv!(
                    α[ind, k],
                    Diagonal(sqrt.(yk .* (1 .- yk))) * Xtmp
                )
            end
            return wtmp, H, ind
        end
    end
    @warn "Not converged after $(maxiter) steps. Results may be inaccurate."
end

"""train + predict"""
function RVM!(
    XH::AbstractMatrix{T}, XL::AbstractMatrix{T}, t::AbstractMatrix{T},
    XLtest::AbstractMatrix{T}, α::AbstractMatrix{T}, β::AbstractMatrix{T};
    rtol=1e-5, atol=1e-7, maxiter=100000, n_samples=2000
) where T<:Real
    # Multinomial
    n = size(X, 1)
    d = size(X, 2)
    size(t, 1) == n || throw(DimensionMismatch("Sizes of X and t mismatch."))
    size(α, 1) == d || throw(DimensionMismatch("Sizes of X and initial α mismatch."))
    K = size(t, 2)  # total number of classes
    size(α, 2) == K || throw(DimensionMismatch("Number of classes and size of α mismatch."))

    wh, H, ind_h = RVM!(
        XH, t, α, tol=tol, maxiter=maxiter
    )
    ind_nonzero = findall(in(findall(x -> x > 1e-3, std(XL, dims=1)[:])), ind_h)
    ind = ind_h[ind_nonzero]
    n_ind = size(ind, 1)
    # initialise
    # preallocate type-II likelihood (evidence) vector
    llh2 = Vector{T}(undef, maxiter)
    fill!(llh2, -Inf)
    # posterior of wh
    wh_samples = Array{T}(undef, n_samples, n_ind * K)
    Threads.@threads for k ∈ 1:K
        wh_samples[:, ((k-1)*n_ind + 1):(k*n_ind)] .= transpose(rand(
            MvNormal(
                wh[ind_nonzero, k],
                H[ind_nonzero, ind_nonzero, k]
            ), n_samples
        ))
    end
    wh_samples = reshape(transpose(wh_samples), n_ind, K, n_samples)
    # screening
    βtmp = @view β[ind, :]
    XLtmp = @view XL[:, ind]
    XLtesttmp = @view XLtest[:, ind]
    #w = ones(T, d, K) * 0.00001
    #αp = ones(T, d, K)
    #A, Y, logY = (Matrix{T}(undef, n, K) for _ = 1:3)
    for iter ∈ 2:maxiter
        ind_l = unique!([item[1] for item in findall(βtmp .< 10000)])
        n_ind_l = size(ind_l, 1)
        #copyto!(αp, α)
        β2 = copy(βtmp[ind_l, :])
        XL2 = copy(XLtmp[:, ind_l])
        g = eachslice(whsamples, dims=3) |>
        Map(
            x -> Logit(
                x, β2, XL2,
                transpose(XL2),
                t, atol, maxiter
            )
        ) |> Broadcasting() |> Folds.sum
        g ./= n_samples
        # update β
        βtmp[ind_l, :] .=
            (1 .- β2 .* g[(n_ind_l+1):(end-1), :]) ./ g[1:n_ind_l, :].^2
        # check convergence
        llh[iter] = sum(g[end, :])
        incr = abs((llh2[iter] - llh2[iter-1]) / llh2[iter-1])
        @info "iteration $iter" incr
        if incr < rtol
            XLtest2 = copy(XLtesttmp[:, ind_l])
            #XLtest2t = transpose(XLtest2t)
            g = eachslice(whsamples, dims=3) |>
            Map(
                x -> Logit(
                    x, β2, XL2,
                    transpose(XL2),
                    t, XLtest2, tol, maxiter
                )
            ) |> Broadcasting() |> Folds.sum
            g ./= n_samples
            return g
        end
    end
    @warn "Not converged after $(maxiter) steps. Results may be inaccurate."
end

function Logit!(
    w::AbstractMatrix{T}, α::AbstractMatrix{T}, X::AbstractMatrix{T},
    t::AbstractMatrix{T}, tol::Float64, maxiter::Int64,
    A::AbstractMatrix{T}, Y::AbstractMatrix{T}, logY::AbstractMatrix{T}
) where T<:Real
    n = size(t, 1)
    d = size(X, 2)
    K = size(t, 2) # number of classes
    Xt = transpose(X)
    ind = findall(x -> x < 10000, α[:])
    #dk = d * Ks
    g, wp, gp = (zeros(T, d, K) for _ = 1:3)
    llhp = -Inf
    mul!(A, X, w)
    LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
    LoopVectorization.@avx Y .= exp.(logY)
    r = [0.0001]  # initial step size
    for iter = 2:maxiter
        # update gradient
        mul!(g, Xt, t .- Y)
        g .-= w .* α
        @info "g" g[ind]
        copyto!(wp, w)
        # update weights
        w[ind] .+= @views g[ind] .* r
        #w .+= g .* r
        mul!(A, X, w)
        LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
        # update likelihood
        llh = -0.5sum(α[ind] .* w[ind] .* w[ind]) + sum(t .* logY)
        #llh = -0.5sum(α .* w .* w) + sum(t .* logY)
        @info "llh" llh
        while (llh - llhp < 0)  # line search
            g ./= 2
            w[ind] .= @views wp[ind] .+ g[ind] .* r
            #w .= wp .+ g .* r
            mul!(A, X, w)
            LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
            llh = -0.5sum(α[ind] .* w[ind] .* w[ind]) + sum(t .* logY)
        end
        #@info "w" w
        LoopVectorization.@avx Y .= exp.(logY)
        #@info "Y" Y
        #@info "incr" abs((llh - llhp) / llhp)
        if llh - llhp < tol
            return llh
        else
            llhp = llh
            # update step sizeß
            r .= @views abs(sum((w[ind] .- wp[ind]) .* (g[ind] .- gp[ind]))) /
                (sum((g[ind] .- gp[ind]) .^ 2) + 1e-2)
            @info "r" r
            #r .= 0.00001
            copyto!(gp, g)
        end
    end
    @warn "not converged."
end

function Logit(
    wh::AbstractMatrix{T}, α::AbstractMatrix{T},
    X::AbstractMatrix{T}, Xt::AbstractMatrix{T},
    t::AbstractMatrix{T}, tol::Float64, maxiter::Int64
) where T<:Real
    # need a sampler
    n, d = size(X)
    K = size(t, 2) # number of classes
    wp, g, gp = (similar(wh) for _ = 1:3)
    wl = copy(wh)
    A, Y, logY = (Matrix{T}(undef, n, K) for _ = 1:3)
    mul!(A, X, wl)
    LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
    LoopVectorization.@avx Y .= exp.(logY)
    llhp = -Inf
    r = [0.00001]
    for iter = 2:maxiter
        # update gradient
        mul!(g, Xt, t .- Y)
        g .-= α .* wl
        #ldiv!(factorize(H), g)
        # update w
        copyto!(wp, wl)
        wl .+= g .* r
        mul!(A, X, wl)
        LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
        llh = -0.5sum(α .* wl .* wl) + sum(t .* logY)
        while llh - llhp < 0.0
            g ./= 2
            wl .= wp .+ g .* r
            mul!(A, X, wl)
            LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
            llh = -0.5sum(α .* wl .* wl) + sum(t .* logY)
        end
        LoopVectorization.@avx Y .= exp.(logY)
        if llh - llhp < tol
            @inbounds for k ∈ 1:K
                yk = view(Y, :, k)
                gk = view(g, :, k)
                αk = view(α, :, k)
                WoodburyInv!(
                    gk, αk,
                    Diagonal(sqrt.(yk .* (1 .- yk))) * X
                )
            end
            return vcat(
                (wl.-wh).^2, g,
                -0.5sum(α .* wl .* wl, dims=1) .+ sum(t .* logY, dims=1)
            )#, llh+0.5logdet(H))
        else
            llhp = llh
            r .= abs(sum((wl .- wp) .* (g .- gp))) ./ sum((g .- gp) .^ 2)
            copyto!(gp, g)
        end
    end
    @warn "Not converged."
end

function Logit(
    wh::AbstractMatrix{T}, α::AbstractMatrix{T},
    X::AbstractMatrix{T}, Xt::AbstractMatrix{T},
    t::AbstractMatrix{T}, Xtest::AbstractMatrix{T},
    tol::Float64, maxiter::Int64
) where T<:Real
    # need a sampler
    n, d = size(X)
    K = size(t, 2) # number of classes
    wp, g, gp = (similar(wh) for _ = 1:3)
    wl = copy(wh)
    A, Y, logY = (Matrix{T}(undef, n, K) for _ = 1:3)
    mul!(A, X, wh)
    LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
    LoopVectorization.@avx Y .= exp.(logY)
    llhp = -Inf
    r = [0.00001]
    for iter = 2:maxiter
        # update gradient
        mul!(g, Xt, t .- Y)
        g .-= α .* wl
        copyto!(wp, wl)
        wl .+= g .* r
        mul!(A, X, wl)
        LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
        llh = -0.5sum(α .* wl .* wl) + sum(t .* logY)
        while llh - llhp < 0.0
            g ./= 2
            wl .= wp .+ g .* r
            mul!(A, X, wl)
            LoopVectorization.@avx logY .= A .- log.(sum(exp.(A), dims=2))
            llh = -0.5sum(α .* wl .* wl) + sum(t .* logY)
        end
        LoopVectorization.@avx Y .= exp.(logY)
        if llh - llhp < tol
            H = Array{T}(undef, d, d, K)
            @inbounds for k ∈ 1:K
                yk = view(Y, :, k)
                αk = view(α, :, k)
                H[:, :, k] .= WoodburyInv!(
                    αk,
                    Diagonal(sqrt.(yk .* (1 .- yk))) * X
                )
                predict!(Y, Xtest, wl, H)
            end
            return Y
        else
            llhp = llh
            r .= abs(sum((wl .- wp) .* (g .- gp))) ./ sum((g .- gp) .^ 2)
            copyto!(gp, g)
        end
    end
    @warn "Not converged."
end
