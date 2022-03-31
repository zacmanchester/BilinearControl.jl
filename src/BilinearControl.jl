module BilinearControl

export BilinearADMM

using LinearAlgebra

include("utils.jl")
include("bilinear_model.jl")
include("problem.jl")
include("admm.jl")

end # module
