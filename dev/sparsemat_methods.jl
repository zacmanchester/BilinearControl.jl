import Pkg; Pkg.activate(@__DIR__)

using BilinearControl
using BilinearControl.Problems
import RobotDynamics as RD
import TrajectoryOptimization as TO
using LinearAlgebra
using StaticArrays
using Statistics
using Rotations
using BilinearControl.Problems: qrot, skew
using SparseArrays
using Test
using BilinearControl: getA, getB, getC, getD
using BenchmarkTools


function getcolvals(A::AbstractSparseMatrix{Tv,Ti}) where {Tv,Ti}
    cv = zeros(Ti,nnz(A))
    for col in axes(A,2)
        for j in nzrange(A, col)
            cv[j] = col
        end
    end
    cv
end

function mulcsc!(y,A,x)
    rv = rowvals(A)
    nzv = nonzeros(A)
    fill!(y, zero(eltype(y)))
    @inbounds for col in axes(A,2)
        for j in nzrange(A, col)
            y[rv[j]] += nzv[j] * x[col]
        end
    end
    y
end

function mulcoo!(y,Acoo,x)
    fill!(y, zero(eltype(y)))
    @inbounds for (r,c,v) in Acoo
        y[r] += v * x[c]
    end
    y
end

function multcsc!(y,A,x)
    rv = rowvals(A)
    nzv = nonzeros(A)
    fill!(y, zero(eltype(y)))
    @inbounds for col in axes(A,2)
        tmp = zero(eltype(y))
        for j in nzrange(A, col)
            tmp += nzv[j] * x[rv[j]]
        end
        y[col] = tmp
    end
    y
end

function multcoo!(y,Acoo,x)
    fill!(y, zero(eltype(y)))
    @inbounds for (r,c,v) in Acoo
        y[c] += v * x[r]
    end
    y
end

function AtAcsc!(y, y0, A, x)
    rv = rowvals(A)
    nzv = nonzeros(A)
    fill!(y0, zero(eltype(y0)))
    @inbounds for col in axes(A,2)
        for j in nzrange(A, col)
            y0[rv[j]] += nzv[j] * x[col]
        end
    end
    y

    fill!(y, zero(eltype(y)))
    @inbounds for col in axes(A,2)
        tmp = zero(eltype(y))
        for j in nzrange(A, col)
            tmp += nzv[j] * y0[rv[j]]
        end
        y[col] = tmp
    end
    y
end
x0 .= 0
y0 .= 0
AtAcsc!(x0, y0, A, x) ≈ A'A*x
@btime AtAcsc!($x0, $y0, $A, $x)

function AtAcoo!(y, y0, A, x)
    fill!(y0, zero(eltype(y0)))
    @inbounds for (r,c,v) in Acoo
        y0[r] += v * x[c]
    end
    fill!(y, zero(eltype(y)))
    @inbounds for (r,c,v) in Acoo
        y[c] += v * y0[r]
    end
    y
end
x0 .= 0
y0 .= 0
AtAcoo!(x0, y0, Acoo, x) ≈ A'A*x


# Normal multiplication
n = 20
m = 5
A = sprandn(n,n,0.2)
x = randn(n)
y = zero(x)
Acoo = collect(zip(findnz(A)...))
mulcsc!(y,A,x) ≈ A*x
mulcoo!(y, Acoo, x) ≈ A*x

multcsc!(x,A,y) ≈ A'y
multcoo!(x,Acoo,y) ≈ A'y

x0 = zero(x)
y0 = zero(y)
AtAcsc!(x0, y0, A, x) ≈ A'A*x

@btime mul!($y,$A,$x)
@btime mulcsc!($y,$A,$x)
@btime mulcoo!($y, $Acoo, $x)

@btime mul!($x,$(A'),$y)
@btime multcsc!($x,$A,$y)
@btime multcoo!($x, $Acoo, $y)

# Calculating AtA
using BilinearControl: getnzind
cache = AtAcache(A)
AtA(A, cache) ≈ A'A

B = A'A
AtA!(B, A, cache) ≈ A'A

@btime mul!($B, $(A'), $A)
@btime $(A')*$A
@btime AtA!($B, $A, $cache)


# Bilinear Term

"""
Compute
    y = sum(z[i] * A[i] * x for i = 1:length(z))
"""
function mulbi!(y,A,x,z)
    fill!(y, zero(eltype(y)))
    for i = 1:length(z)
        mul!(y, A[i], x, z[i], 1.0)
    end
    y
end

function mulbicoo!(y,Acoo,x,z)
    fill!(y, zero(eltype(y)))
    @inbounds for (r,c,v,i) in Acoo
        y[r] += v * x[c] * z[i]
    end
    y
end
C = [sprandn(n,n,0.2) for i = 1:m]
nnzC = sum(nnz, C)
Ccoo = Tuple{Int,Int,Float64,Int}[]
for (i,c) in enumerate(C) 
    for (r,c,v) in zip(findnz(c)...)
        push!(Ccoo, (r,c,v,i))
    end
end
length(Ccoo) == nnzC

z = randn(m)
mulbi!(y,C,x,z) ≈ sum(z[i] * C[i] * x for i = 1:m)
mulbicoo!(y, Ccoo, x, z) ≈ sum(z[i] * C[i] * x for i = 1:m)

@btime mulbi!($y,$C,$x,$z)
@btime mulbicoo!($y,$Ccoo,$x,$z)


# Quadrotor
model = QuadrotorSE23()
A,B,C,D = getA(model), getB(model), getC(model), getD(model)
A = sparse(A)

x,u = Vector.(rand(model))
y = zeros(size(A,1))