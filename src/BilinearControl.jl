module BilinearControl

export BilinearADMM, Problems, RiccatiSolver, TOQP, DiscreteLinearModel

export extractstatevec, extractcontrolvec, iterations, tovecs, plotstates, plotstates!

using LinearAlgebra
using SparseArrays
using StaticArrays
using OSQP
using RecipesBase
import Convex
import COSMO
import IterativeSolvers 
import RobotDynamics as RD
import TrajectoryOptimization as TO
import COSMOAccelerators
# import Ipopt
import MathOptInterface as MOI

import RobotDynamics: state_dim, control_dim

import TrajectoryOptimization: state_dim, control_dim

include("utils.jl")
include("bilinear_constraint.jl")
include("bilinear_model.jl")
include("admm.jl")
include("trajopt_interface.jl")
include("mpc.jl")

# include("sparseblocks.jl")
# include("moi.jl")

include("gen_controllable.jl")
include("linear_model.jl")
include("trajopt_qp.jl")
include("lqr_solver.jl")

include("linear_admm.jl")

include("edmd/edmd.jl")
include(joinpath(@__DIR__,"..","examples","Problems.jl"))
include("problem.jl")

end # module
