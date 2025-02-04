## Caches

function CachedOperator(intop::InterlaceOperator{T,1};padding::Bool = false) where T
    ds = domainspace(intop)
    rs = rangespace(intop)

    ind = findall(op->isinf(size(op,1))::Bool, intop.ops)
    if length(ind) ≠ 1  || !isbanded(intop.ops[ind[1]])::Bool  # is almost banded
        return default_CachedOperator(intop; padding)
    end
    i = ind[1]
    bo = intop.ops[i]
    lin,uin = bandwidths(bo)



    # calculate number of rows interlaced
    # each each row in the rangespace increases the lower bandwidth by 1
    nds = 0
    md = 0
    for k = 1:length(intop.ops)
        if k ≠ i
            d = dimension(component(rs,k))
            nds+=d
            md = max(md,d)
        end
    end


    isend = true
    for k = i+1:length(intop.ops)
        if dimension(component(rs,k)) == md
            isend = false
        end
    end

    numoprows = isend ? md-1 : md
    n = nds+numoprows

    (l,u) = (max(lin+nds,n-1),max(0,uin+1-ind[1]))

    # add extra rows for QR
    if padding
        u+=l
    end


    ret = AlmostBandedMatrix(Zeros{T}(n,n+u),(l,u),nds)

    # populate the finite rows
    jr = 1:n+u
    ioM = intop[1:n,jr]


    bcrow = 1
    oprow = 0
    for k = 1:n
        K,J = intop.rangeinterlacer[k]

        if K ≠ i
            # fill the fill matrix
            ret.fill.V[:,bcrow] = Matrix(view(intop.ops[K],J:J,jr))
            ret.fill.U[k,bcrow] = 1
            bcrow += 1
        else
            oprow += 1
        end


        for j = rowrange(ret.bands,k)
            ret[k,j] = ioM[k,j]
        end
    end


    CachedOperator(intop,ret,(n,n+u),ds,rs,(l,∞))
end


function CachedOperator(intop::InterlaceOperator{T,2};padding::Bool = false) where T
    ds = domainspace(intop)
    rs = rangespace(intop)
    di = intop.domaininterlacer
    ri = intop.rangeinterlacer
    ddims = dimensions(di.iterator)
    rdims = dimensions(ri.iterator)

    # we are only almost banded if every operator is either finite
    # range or banded, and if the # of  ∞ spaces is the same
    # for the domain and range
    isab = all(op->isfinite(size(op,1)) || isbanded(op),intop.ops) &&
        count(isinf,ddims) == count(isinf,rdims)

    if !isab
        return default_CachedOperator(intop;padding = padding)
    end


    # these are the bandwidths if we only had ∞-dimensional operators
    d∞=findall(isinf,collect(ddims))
    r∞=findall(isinf,collect(rdims))
    p = length(d∞)

    # we only support block size 1 for now
    for k in d∞
        bl = blocklengths(component(ds,k))
        if !(bl isa AbstractFill) || getindex_value(bl) ≠ 1
            return default_CachedOperator(intop;padding = padding)
        end
    end
    for k in r∞
        bl = blocklengths(component(rs,k))
        if !(bl isa AbstractFill) || getindex_value(bl) ≠ 1
            return default_CachedOperator(intop;padding = padding)
        end
    end

    l∞,u∞ = 0,0
    for k = 1:p, j = 1:p
        l∞ = max(l∞, p*bandwidth(intop.ops[r∞[k],d∞[j]],1)+k-j)
        u∞ = max(u∞, p*bandwidth(intop.ops[r∞[k],d∞[j]],2)+j-k)
    end

    # now we move everything by the finite rank
    ncols = mapreduce(d->isfinite(d) ? d : 0,+,ddims)
    nbcs = mapreduce(d->isfinite(d) ? d : 0,+,rdims)
    shft = ncols-nbcs
    l∞, u∞ = l∞ - shft, u∞ + shft

    # iterate through finite rows to find worst case bandwidth
    l,u = l∞,u∞
    for k = 1+nbcs+p,j = 1:ncols+p
        N,n = ri[k]
        M,m = di[j]
        l = max(l,bandwidth(intop.ops[N,M],1)+m-n+k-j)
        u = max(u,bandwidth(intop.ops[N,M],2)+n-m+j-k)
    end


    # add extra rows for QR
    if padding
        u += l
    end

    n = 1+nbcs+p
    ret = AlmostBandedMatrix(Zeros{T}(n,n+u),(l,u),nbcs)

    # populate entries and fill functionals
    bcrow = 1
    oprow = 0
    jr = 1:n+u
    for k = 1:n
        K,J = intop.rangeinterlacer[k]

        if isfinite(rdims[K] )
            # fill the fill matrix
            ret.fill.V[:,bcrow] = Matrix(view(intop,k:k,jr))
            ret.fill.U[k,bcrow] = 1
            bcrow += 1
        else
            oprow+=1
        end


        for j = rowrange(ret.bands,k)
            ret[k,j] = intop[k,j]
        end
    end

    CachedOperator(intop,ret,(n,n+u),ds,rs,(l,∞))
end



# Grow cached interlace operator

function resizedata!(co::CachedOperator{T,<:AlmostBandedMatrix{T},<:InterlaceOperator{T,1}},
        n::Integer,::Colon) where {T<:Number}
    if n ≤ co.datasize[1]
        return co
    end

    (l,u)=bandwidths(co.data.bands)
    co.data = pad(co.data, n, n+u)

    r = rank(co.data.fill)
    ind = findfirst(op->isinf(size(op,1)),co.op.ops)

    k = 1
    for (K,J) in co.op.rangeinterlacer
        if K ≠ ind
            co.data.fill.V[co.datasize[2]:end,k] = co.op.ops[K][J,co.datasize[2]:n+u]
            k += 1
            if k > r
                break
            end
        end
    end

    kr = co.datasize[1]+1:n
    jr = max(1,kr[1]-l):n+u
    axpy!(1.0,view(co.op.ops[ind],kr .- r,jr),
                    view(co.data.bands,kr,jr))

    co.datasize=(n,n+u)
    co
end



function resizedata!(co::CachedOperator{T,<:AlmostBandedMatrix{T},<:InterlaceOperator{T,2}},
        n::Integer,::Colon) where {T<:Number}
    if n ≤ co.datasize[1]
        return co
    end

    intop = co.op
    ds = domainspace(intop)
    rs = rangespace(intop)
    di = intop.domaininterlacer
    ri = intop.rangeinterlacer
    ddims = dimensions(di.iterator)
    rdims = dimensions(ri.iterator)

    d∞=findall(isinf,collect(ddims))
    r∞=findall(isinf,collect(rdims))
    p = length(d∞)

    (l,u)=bandwidths(co.data.bands)
    co.data = pad(co.data,n,n+u)
    # r is number of extra rows, ncols is number of extra columns
    r = rank(co.data.fill)
    ncols = mapreduce(d->isfinite(d) ? d : 0,+,ddims)


    # fill rows
    K = k=1
    while k ≤ r
        if isfinite(dimension(component(rs,ri[K][1])))
            co.data.fill.V[co.datasize[2]:end,k] = co.op[K,co.datasize[2]:n+u]
            k += 1
        end
        K += 1
    end

    kr = co.datasize[1]+1:n
    jr = max(ncols+1,kr[1]-l):n+u
    intop∞=InterlaceOperator(intop.ops[r∞,d∞])

    axpy!(1.0,view(intop∞,kr.-r,jr.-ncols),view(co.data.bands,kr,jr))

    co.datasize=(n,n+u)
    co
end


resizedata!(co::CachedOperator{T,<:AlmostBandedMatrix{T},<:InterlaceOperator{T,1}},
    n::Integer,m::Integer) where {T<:Number} = resizedata!(co,max(n,m+bandwidth(co.data.bands,1)),:)


resizedata!(co::CachedOperator{T,<:AlmostBandedMatrix{T},<:InterlaceOperator{T,2}},
    n::Integer,m::Integer) where {T<:Number} = resizedata!(co,max(n,m+bandwidth(co.data.bands,1)),:)



##
# These give highly optimized routines for delaying with Cached
#

## QR


function QROperator(R::CachedOperator{T,<:AlmostBandedMatrix{T}}) where T
    M = R.data.bands.l+1   # number of diag+subdiagonal bands
    H = Matrix{T}(undef,M,100)
    QROperator(R,H,0)
end


function resizedata!(QR::QROperator{<:CachedOperator{T,<:AlmostBandedMatrix{T}}}, ::Colon, col) where {T}
    if col ≤ QR.ncols
        return QR
    end

    MO = QR.R_cache
    W = QR.H

    Rl, Ru = bandwidths(MO.data.bands)
    M = Rl + 1   # number of diag+subdiagonal bands

    if col+M-1 ≥ MO.datasize[1]
        resizedata!(MO,(col+M-1)+100,:)  # double the last rows
    end

    R = MO.data.bands # has to be accessed after the resizedata!

    if col > size(W,2)
        W = QR.H = unsafe_resize!(W,:,2col)
    end

    F = MO.data.fill.U

    for k = QR.ncols+1:col
        W[:,k] = view(R.data, (Ru+1).+(0:Rl), k) # diagonal and below
        wp = view(W,:,k)
        W[1,k]+= flipsign(norm(wp),W[1,k])
        normalize!(wp)

        # scale banded entries
        for j = k.+(0:Ru)
            dind = Ru+1+k-j
            v = view(R.data, range(dind, length=M), j)
            dt = dot(wp,v)
            axpy!(-2dt,wp,v)
        end

        # scale banded/filled entries
        for j = (k+Ru).+(1:M-1)
            p = j-k-Ru
            v = view(R.data,1:M-p,j)  # shift down each time
            wp2=view(wp,p+1:M)
            dt = dot(wp2,v)
            for ℓ in range(k, length=p)
                dt = muladd(conj(W[ℓ-k+1,k]), MO.data.fill[ℓ,j], dt)
            end
            axpy!(-2dt,wp2,v)
        end

        # scale filled entries

        for j = axes(F,2)
            v = view(F, range(k,length=M), j) # the k,jth entry of F
            dt = dot(wp,v)
            axpy!(-2dt,wp,v)
        end
    end
    QR.ncols = col
    QR
end


## back substitution
# loop to avoid ambiguity with AbstractTRiangular
for ArrTyp in (:AbstractVector, :AbstractMatrix)
    @eval function ldiv!(U::UpperTriangular{T,<:SubArray{T, 2, <:AlmostBandedMatrix{T}, NTuple{2,UnitRange{Int}}}},
                u::$ArrTyp{T}) where T

        n = size(u,1)
        n == size(U,1) || throw(DimensionMismatch())

        V = parent(U)
        @assert parentindices(V)[1][1] == 1
        @assert parentindices(V)[2][1] == 1

        B = parent(V)

        A = B.bands
        F = B.fill
        b = bandwidth(A,2)
        nbc = rank(B.fill)

        pk = zeros(T,nbc)

        for c = axes(u,2)
            fill!(pk,zero(T))

            # before we get to filled rows
            for k = n:-1:max(1,n-b)
                @simd for j = k+1:n
                    @inbounds u[k,c] = muladd(-A.data[k-j+A.u+1,j],u[j,c],u[k,c])
                end

                @inbounds u[k,c] /= A.data[A.u+1,k]
            end

           #filled rows
            for k = n-b-1:-1:1
                @simd for j = 1:nbc
                    @inbounds pk[j] = muladd(u[k+b+1,c],F.V[k+b+1,j],pk[j])
                end

                @simd for j = k+1:k+b
                    @inbounds u[k,c]=muladd(-A.data[k-j+A.u+1,j],u[j,c],u[k,c])
                end

                @simd for j = 1:nbc
                    @inbounds u[k,c] = muladd(-F.U[k,j],pk[j],u[k,c])
                end

                @inbounds u[k,c] /= A.data[A.u+1,k]
            end
        end
        u
    end
end
