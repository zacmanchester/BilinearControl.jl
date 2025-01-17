import Pkg; Pkg.activate(joinpath(@__DIR__)); Pkg.instantiate();
using BilinearControl
using BilinearControl.Problems
using BilinearControl.EDMD
import RobotDynamics as RD
using LinearAlgebra
using RobotZoo
using JLD2
using SparseArrays
using Plots
using Distributions
using Distributions: Normal
using Random
using FiniteDiff, ForwardDiff
using Test
using PGFPlotsX
using Statistics
using LaTeXStrings

include("constants.jl")
const REX_PLANAR_QUADROTOR_RESULTS_FILE = joinpath(Problems.DATADIR, "rex_planar_quadrotor_lqr_results.jld2")

function test_initial_conditions(model, controller, xg, ics, tf, dt)
    map(ics) do x0
        X_sim, = simulatewithcontroller(model, controller, x0, tf, dt)
        norm(X_sim[end] - xg)
    end
end

function test_initial_conditions_offset(model, controller, xg, ics, tf, dt)
    map(ics) do x0
        X_sim, = simulatewithcontroller(model, controller, x0+xg, tf, dt)
        norm(X_sim[end] - xg)
    end
end

## Visualizer
model = Problems.RexPlanarQuadrotor()
include(joinpath(Problems.VISDIR, "visualization.jl"))
vis = Visualizer()
delete!(vis)
set_quadrotor!( vis, model)
render(vis)

#############################################
## Define the models 
#############################################

# Define Nominal Simulated REx Planar Quadrotor Model
model_nom = Problems.NominalPlanarQuadrotor()
dmodel_nom = RD.DiscretizedDynamics{RD.RK4}(model_nom)

# Define Mismatched "Real" REx Planar Quadrotor Model
model_real = Problems.SimulatedPlanarQuadrotor()  # this model has aero drag
dmodel_real = RD.DiscretizedDynamics{RD.RK4}(model_real)

#############################################
## Generate Training and Test Data 
#############################################
tf = 5.0
dt = 0.05

# Generate Data From Mismatched Model
Random.seed!(1)

# Number of trajectories
num_train = 30

# Generate a stabilizing LQR controller
Qlqr = Diagonal([10.0, 10.0, 10.0, 1.0, 1.0, 1.0])
Rlqr = Diagonal([1e-4, 1e-4])
xe = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
ue = Problems.trim_controls(model_real)
ctrl_lqr_nom = LQRController(dmodel_nom, Qlqr, Rlqr, xe, ue, dt)

# Sample a bunch of initial conditions for the LQR controller
x0_train_sampler = Product([
    Uniform(-1.0,1.0),
    Uniform(-1.0,1.0),
    Uniform(-deg2rad(40),deg2rad(40)),
    Uniform(-0.5,0.5),
    Uniform(-0.5,0.5),
    Uniform(-0.25,0.25)
])

initial_conditions_lqr = [rand(x0_train_sampler) for _ in 1:num_train]

# Create data set
X_train, U_train = create_data(dmodel_real, ctrl_lqr_nom, initial_conditions_lqr, tf, dt)

#############################################
## Define basis functions
#############################################

eigfuns = ["state", "sine", "cosine", "chebyshev"]
eigorders = [[0],[1],[1],[2,2]]

#############################################
## Tracking error vs regularization 
#############################################

perc = 2.0
x0_sampler = Product([
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-deg2rad(40*perc),deg2rad(40*perc)),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.25*perc,0.25*perc)
])

x0_test = [rand(x0_sampler) for i = 1:100]
t_sim = 5.0

Qlqr = Diagonal([10.0, 10.0, 10.0, 1.0, 1.0, 1.0])
Rlqr = Diagonal([1e-4, 1e-4])

regularizers = vcat(0.0, exp10.(-5:2))
errors = map(regularizers) do reg
    model_eDMD = run_eDMD(X_train, U_train, dt, eigfuns, eigorders, reg=reg, name="planar_quadrotor_eDMD")
    model_eDMD_projected = EDMD.ProjectedEDMDModel(model_eDMD)
    lqr_eDMD_projected = LQRController(
    model_eDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true
    )
    error_eDMD_projected = mean(test_initial_conditions(dmodel_real, lqr_eDMD_projected, xe, x0_test, t_sim, dt))

    if reg == 0
        error_jDMD_projected = NaN
    else
        model_jDMD = run_jDMD(X_train, U_train, dt, eigfuns, eigorders, dmodel_nom, reg=reg, name="planar_quadrotor_jDMD")
        model_jDMD_projected = EDMD.ProjectedEDMDModel(model_jDMD)
        lqr_jDMD_projected = LQRController(
            model_jDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true
        )
        error_jDMD_projected = mean(test_initial_conditions(dmodel_real, lqr_jDMD_projected, xe, x0_test, t_sim, dt))
    end

    (;error_eDMD_projected, error_jDMD_projected)

end
fields = keys(errors[1])
res_reg = Dict(Pair.(fields, map(x->getfield.(errors, x), fields)))

#############################################
## Fit the training data
#############################################

model_eDMD = run_eDMD(X_train, U_train, dt, eigfuns, eigorders, reg=1e-1, name="planar_quadrotor_eDMD")
model_eDMD_unreg = run_eDMD(X_train, U_train, dt, eigfuns, eigorders, reg=0.0, name="planar_quadrotor_eDMD")
model_jDMD = run_jDMD(X_train, U_train, dt, eigfuns, eigorders, dmodel_nom, reg=1e-5, name="planar_quadrotor_jDMD")
model_jDMD2 = run_jDMD(X_train, U_train, dt, eigfuns, eigorders, dmodel_nom, reg=1e-1, name="planar_quadrotor_jDMD")

model_eDMD_projected = EDMD.ProjectedEDMDModel(model_eDMD)
model_eDMD_projected_unreg = EDMD.ProjectedEDMDModel(model_eDMD_unreg)
model_jDMD_projected = EDMD.ProjectedEDMDModel(model_jDMD)
model_jDMD_projected2 = EDMD.ProjectedEDMDModel(model_jDMD2)

n,m = RD.dims(model_eDMD)
n0, = RD.dims(model_real)

#############################################
## Plot an LQR Trajectory
#############################################

# ze = RD.KnotPoint{n0,m}(xe,ue,0.0,dt)
# ye = EDMD.expandstate(model_eDMD, xe)

# ## Create LQR controllers
# ctrl_lqr_real = EDMD.LQRController(dmodel_real, Qlqr, Rlqr, xe, ue, dt)
# ctrl_lqr_nom = EDMD.LQRController(dmodel_nom, Qlqr, Rlqr, xe, ue, dt)
# ctrl_lqr_eDMD = EDMD.LQRController(model_eDMD_projected, Qlqr, Rlqr, xe, ue, dt)
# ctrl_lqr_jDMD = EDMD.LQRController(model_jDMD_projected, Qlqr, Rlqr, xe, ue, dt)

# ## Simulate with specified initial condition
# tf_sim = 5.0
# Tsim_lqr = range(0,tf_sim,step=dt)
# x0 = [-0.5, 0.5, -deg2rad(20),-1.0,1.0,0.0]

# Xsim_lqr_real, = EDMD.simulatewithcontroller(dmodel_real, ctrl_lqr_real, x0, tf_sim, dt)
# Xsim_lqr_nom, = EDMD.simulatewithcontroller(dmodel_real, ctrl_lqr_nom, x0, tf_sim, dt)
# Xsim_lqr_eDMD, = EDMD.simulatewithcontroller(dmodel_real, ctrl_lqr_eDMD, x0, tf_sim, dt)
# Xsim_lqr_jDMD, = EDMD.simulatewithcontroller(dmodel_real, ctrl_lqr_jDMD, x0, tf_sim, dt)

# plotstates(Tsim_lqr, Xsim_lqr_real, inds=1:3, xlabel="time (s)", ylabel="states",
#             label=["x (true LQR)" "y (true LQR)" "θ (true LQR)"], legend=:topright, lw=2,
#             linestyle=:dot, color=[1 2 3])
# plotstates!(Tsim_lqr, Xsim_lqr_nom, inds=1:3, xlabel="time (s)", ylabel="states",
#             label=["x (nominal LQR)" "y (nominal LQR)" "θ (nominal LQR)"], legend=:topright, lw=2,
#             linestyle=:dash, color=[1 2 3])
# plotstates!(Tsim_lqr, Xsim_lqr_eDMD, inds=1:3, xlabel="time (s)", ylabel="states",
#             label=["x (nominal EDMD)" "y (nominal eDMD)" "θ (nominal eDMD)"], legend=:topright, lw=2,
#             linestyle=:dashdot, color=[1 2 3])
# plotstates!(Tsim_lqr, Xsim_lqr_jDMD, inds=1:3, xlabel="time (s)", ylabel="states",
#             label=["x (JDMD)" "y (JDMD)" "θ (JDMD)"], legend=:bottomright, lw=2,
#             color=[1 2 3])

# ylims!((-1.25,0.75))

#############################################
## LQR Performance
#############################################

# Equilibrium position
xe = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
ue = Problems.trim_controls(model_real)
ye = EDMD.expandstate(model_eDMD, xe)

Qlqr = Diagonal([10.0, 10.0, 10.0, 1.0, 1.0, 1.0])
Rlqr = Diagonal([1e-4, 1e-4])

ρ = 1e-6 
Qlqr_lifted = Diagonal([ρ; diag(Qlqr); fill(ρ, length(ye) - 7)])

# Nominal LQR Controller
lqr_nominal = LQRController(
    dmodel_nom, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true
)

# Projected LQR Controllers
model_eDMD_projected = EDMD.ProjectedEDMDModel(model_eDMD)
model_jDMD_projected = EDMD.ProjectedEDMDModel(model_jDMD)
lqr_eDMD_projected = LQRController(
    model_eDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true
)
lqr_jDMD_projected = LQRController(
    model_jDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true
)

# Lifted LQR Controllers
lifted_state_error(x,x0) = model_eDMD.kf(x) - x0
lqr_jDMD = LQRController(
    model_jDMD, Qlqr_lifted, Rlqr, ye, ue, dt, max_iters=20000, verbose=true,
    state_error=lifted_state_error
)
lqr_eDMD = LQRController(
    model_eDMD, Qlqr_lifted, Rlqr, ye, ue, dt, max_iters=10000, verbose=true,
    state_error=lifted_state_error
)

# Run each controller on the same set of initial conditions
Random.seed!(2)

perc = 2.0
x0_sampler = Product([
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-deg2rad(40*perc),deg2rad(40*perc)),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.25*perc,0.25*perc)
])

t_sim = 5.0
x0_test = [rand(x0_sampler) for i = 1:100]
errors_nominal = sort!(test_initial_conditions(dmodel_real, lqr_nominal, xe, x0_test, t_sim, dt))
errors_eDMD_projected = sort!(test_initial_conditions(dmodel_real, lqr_eDMD_projected, xe, x0_test, t_sim, dt))
errors_jDMD_projected = sort!(test_initial_conditions(dmodel_real, lqr_jDMD_projected, xe, x0_test, t_sim, dt))
errors_eDMD = sort!(test_initial_conditions(dmodel_real, lqr_eDMD, xe, x0_test, t_sim, dt))
errors_jDMD = sort!(test_initial_conditions(dmodel_real, lqr_jDMD, xe, x0_test, t_sim, dt))

res_lqr_perf = (;errors_nominal, errors_eDMD_projected, errors_jDMD_projected, errors_eDMD, errors_jDMD)

#############################################
## LQR Stabilization Performance vs Training Window
#############################################
percentages = 0.1:0.05:2.5
errors = map(percentages) do perc

    println("percentage of training window = $perc")

    x0_sampler = Product([
        Uniform(-1.0*perc,1.0*perc),
        Uniform(-1.0*perc,1.0*perc),
        Uniform(-deg2rad(40*perc),deg2rad(40*perc)),
        Uniform(-0.5*perc,0.5*perc),
        Uniform(-0.5*perc,0.5*perc),
        Uniform(-0.25*perc,0.25*perc)
    ])

    x0_test = [rand(x0_sampler) for i = 1:100]

    lqr_eDMD_projected = LQRController(
        model_eDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
    lqr_eDMD_projected_unreg = LQRController(
        model_eDMD_projected_unreg, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
    lqr_jDMD_projected = LQRController(
        model_jDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
    lqr_jDMD_projected2 = LQRController(
        model_jDMD_projected2, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)

    error_eDMD_projected = mean(test_initial_conditions(dmodel_real, lqr_eDMD_projected, xe, x0_test, t_sim, dt))
    error_eDMD_projected_unreg = mean(test_initial_conditions(dmodel_real, lqr_eDMD_projected_unreg, xe, x0_test, t_sim, dt))
    error_jDMD_projected = mean(test_initial_conditions(dmodel_real, lqr_jDMD_projected, xe, x0_test, t_sim, dt))
    error_jDMD_projected2 = mean(test_initial_conditions(dmodel_real, lqr_jDMD_projected2, xe, x0_test, t_sim, dt))

    (;error_eDMD_projected, error_eDMD_projected_unreg, error_jDMD_projected, error_jDMD_projected2)

end

fields = keys(errors[1])
res_lqr_window = Dict(Pair.(fields, map(x->getfield.(errors, x), fields)))

# p_lqr_window = @pgf Axis(
#     {
#         xmajorgrids,
#         ymajorgrids,
#         xlabel = "Fraction of Training Range",
#         ylabel = "Stabilization error",
#         legend_pos = "north west",
#         ymax = 20,
#     },
#     PlotInc({lineopts..., color=color_eDMD}, Coordinates(percentages, res_lqr_window[:error_eDMD_projected_unreg])),
#     PlotInc({lineopts..., color="teal"}, Coordinates(percentages, res_lqr_window[:error_eDMD_projected])),
#     PlotInc({lineopts..., color=color_jDMD}, Coordinates(percentages, res_lqr_window[:error_jDMD_projected])),
#     PlotInc({lineopts..., color="purple"}, Coordinates(percentages, res_lqr_window[:error_jDMD_projected2])),

#     Legend(["eDMD" * L"(\lambda = 0.0)", "eDMD" * L"(\lambda = 0.1)", "jDMD" * L"(\lambda = 10^{-5})", "jDMD" * L"(\lambda = 0.1)"])
# )

#############################################
## LQR stabilization performance vs equilibrium change
#############################################

distances = 0:0.1:4
errors = map(distances) do dist

    println("equilibrium offset = $dist")

    if dist == 0
        xe_test = [zeros(6)]
    else
        xe_sampler = Product([
            Uniform(-dist, +dist),
            Uniform(-dist, +dist),
        ])
        xe_test = [vcat(rand(xe_sampler), zeros(4)) for i = 1:100]
    end

    perc = 0.8
    x0_sampler = Product([
        Uniform(-1.0*perc,1.0*perc),
        Uniform(-1.0*perc,1.0*perc),
        Uniform(-deg2rad(40*perc),deg2rad(40*perc)),
        Uniform(-0.5*perc,0.5*perc),
        Uniform(-0.5*perc,0.5*perc),
        Uniform(-0.25*perc,0.25*perc)
    ])

    x0_test = [rand(x0_sampler) for i = 1:100]

    xe_results = map(xe_test) do xe
        lqr_eDMD_projected = LQRController(
            model_eDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
        lqr_eDMD_projected_unreg = LQRController(
            model_eDMD_projected_unreg, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
        lqr_jDMD_projected = LQRController(
            model_jDMD_projected, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
        lqr_jDMD_projected2 = LQRController(
            model_jDMD_projected2, Qlqr, Rlqr, xe, ue, dt, max_iters=10000, verbose=true)
    
        error_eDMD_projected_x0s = mean(test_initial_conditions_offset(dmodel_real, lqr_eDMD_projected, xe, x0_test, t_sim, dt))
        error_eDMD_projected_unreg_x0s = mean(test_initial_conditions_offset(dmodel_real, lqr_eDMD_projected_unreg, xe, x0_test, t_sim, dt))
        error_jDMD_projected_x0s = mean(test_initial_conditions_offset(dmodel_real, lqr_jDMD_projected, xe, x0_test, t_sim, dt))
        error_jDMD_projected2_x0s = mean(test_initial_conditions_offset(dmodel_real, lqr_jDMD_projected2, xe, x0_test, t_sim, dt))

        if error_eDMD_projected_x0s > 1e3
            error_eDMD_projected_x0s = NaN
        end
        if error_eDMD_projected_unreg_x0s > 1e3
            error_eDMD_projected_unreg_x0s = NaN
        end
        if error_jDMD_projected_x0s > 1e3
            error_jDMD_projected_x0s = NaN
        end
        if error_jDMD_projected2_x0s > 1e3
            error_jDMD_projected2_x0s = NaN
        end
        (;error_eDMD_projected_x0s, error_eDMD_projected_unreg_x0s, error_jDMD_projected_x0s, error_jDMD_projected2_x0s)
    end
    
    error_eDMD_projected = mean(filter(isfinite, map(x->x.error_eDMD_projected_x0s, xe_results)))
    error_eDMD_projected_unreg = mean(filter(isfinite, map(x->x.error_eDMD_projected_unreg_x0s, xe_results)))
    error_jDMD_projected = mean(filter(isfinite, map(x->x.error_jDMD_projected_x0s, xe_results)))
    error_jDMD_projected2 = mean(filter(isfinite, map(x->x.error_jDMD_projected2_x0s, xe_results)))

    (;error_eDMD_projected, error_eDMD_projected_unreg, error_jDMD_projected, error_jDMD_projected2)

end

fields = keys(errors[1])
res_equilibrium = Dict(Pair.(fields, map(x->getfield.(errors, x), fields)))

# p_lqr_equilibrium = @pgf Axis(
#     {
#         xmajorgrids,
#         ymajorgrids,
#         xlabel = "Equilibirum offset",
#         ylabel = "Stabilization error",
#         legend_pos = "north west",
#         ymax = 150,
        
#     },
#     PlotInc({lineopts..., color=color_eDMD}, Coordinates(distances, res_equilibrium[:error_eDMD_projected_unreg])),
#     PlotInc({lineopts..., color="teal"}, Coordinates(distances, res_equilibrium[:error_eDMD_projected])),
#     PlotInc({lineopts..., color=color_jDMD}, Coordinates(distances, res_equilibrium[:error_jDMD_projected])),
#     PlotInc({lineopts..., color="purple"}, Coordinates(distances, res_equilibrium[:error_jDMD_projected2])),

#     Legend(["eDMD" * L"(\lambda = 0.0)", "eDMD" * L"(\lambda = 0.1)", "jDMD" * L"(\lambda = 10^{-5})", "jDMD" * L"(\lambda = 0.1)"])
# )

#############################################
## MPC Stabilization Performance 
#############################################

# Reference Trajectory
T_ref = range(0,t_sim,step=dt)
X_ref = [copy(xe) for t in T_ref]
U_ref = [copy(ue) for t in T_ref]
Y_ref = model_eDMD.kf.(X_ref)
Nt = 41

# Objective
Qmpc = copy(Qlqr)
Rmpc = copy(Rlqr)
Qfmpc = 100*Qmpc

Qmpc_lifted = Diagonal([ρ; diag(Qmpc); fill(ρ, length(ye)-7)])
Qfmpc_lifted = Diagonal([ρ; diag(Qfmpc); fill(ρ, length(ye)-7)])

# Nominal MPC controller
mpc_nominal = TrackingMPC(dmodel_nom, 
    X_ref, U_ref, Vector(T_ref), Qmpc, Rmpc, Qfmpc; Nt=Nt
)

# Projected MPC controllers
model_eDMD_projected = EDMD.ProjectedEDMDModel(model_eDMD)
model_jDMD_projected = EDMD.ProjectedEDMDModel(model_jDMD)
mpc_eDMD_projected = TrackingMPC(model_eDMD_projected, 
    X_ref, U_ref, Vector(T_ref), Qmpc, Rmpc, Qfmpc; Nt=Nt
)
mpc_jDMD_projected = TrackingMPC(model_jDMD_projected, 
    X_ref, U_ref, Vector(T_ref), Qmpc, Rmpc, Qfmpc; Nt=Nt
)

# Lifted MPC controllers
mpc_eDMD = TrackingMPC(model_eDMD, 
    Y_ref, U_ref, Vector(T_ref), Qmpc_lifted, Rmpc, Qfmpc_lifted; Nt=Nt, state_error=lifted_state_error
)
mpc_jDMD = TrackingMPC(model_jDMD, 
    Y_ref, U_ref, Vector(T_ref), Qmpc_lifted, Rmpc, Qfmpc_lifted; Nt=Nt, state_error=lifted_state_error
)

# Run each controller on the same set of initial conditions
Random.seed!(2)

perc = 2.0
x0_sampler = Product([
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-1.0*perc,1.0*perc),
    Uniform(-deg2rad(40*perc),deg2rad(40*perc)),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.5*perc,0.5*perc),
    Uniform(-0.25*perc,0.25*perc)
])

x0_test = [rand(x0_sampler) for i = 1:100]
errors_nominal = sort!(test_initial_conditions(dmodel_real, mpc_nominal, xe, x0_test, t_sim, dt))
errors_eDMD_projected = sort!(test_initial_conditions(dmodel_real, mpc_eDMD_projected, xe, x0_test, t_sim, dt))
errors_jDMD_projected = sort!(test_initial_conditions(dmodel_real, mpc_jDMD_projected, xe, x0_test, t_sim, dt))
errors_eDMD = sort!(test_initial_conditions(dmodel_real, mpc_eDMD, xe, x0_test, t_sim, dt))
errors_jDMD = sort!(test_initial_conditions(dmodel_real, mpc_jDMD, xe, x0_test, t_sim, dt))

res_mpc_tracking = (; errors_nominal, errors_eDMD_projected, errors_jDMD_projected, errors_eDMD, errors_jDMD)

#############################################
## Save results
#############################################
jldsave(REX_PLANAR_QUADROTOR_RESULTS_FILE; regularizers, 
    res_reg, res_lqr_perf, percentages, res_lqr_window, 
    distances, res_equilibrium, res_mpc_tracking)

#############################################
## Load and plot results
#############################################
results = load(REX_PLANAR_QUADROTOR_RESULTS_FILE)

regularizers = results["regularizers"]
percentages = results["percentages"]
distances = results["distances"]

res_reg = results["res_reg"]
res_lqr_perf = results["res_lqr_perf"]
res_lqr_window = results["res_lqr_window"]
res_equilibrium = results["res_equilibrium"]
res_mpc_tracking = results["res_mpc_tracking"]

p_lqr_reg = @pgf Axis(
    {
        xmajorgrids,
        ymajorgrids,
        xmode = "log",
        ymode = "log",
        xlabel = "Regularization value",
        ylabel = "Stabilization error",
        legend_pos = "north west"
    },
    PlotInc({lineopts..., color=color_eDMD}, Coordinates(regularizers, res_reg[:error_eDMD_projected])),
    PlotInc({lineopts..., color=color_jDMD}, Coordinates(regularizers, res_reg[:error_jDMD_projected])),
    Legend(["eDMD", "jDMD"])
)
pgfsave(joinpath(Problems.FIGDIR, "rex_planar_quadrotor_lqr_error_by_reg.tikz"), p_lqr_reg, include_preamble=false)

p_lqr_perf = @pgf Axis(
    {
        xmajorgrids,
        ymajorgrids,
        xlabel="Percent of samples",
        ylabel="Tracking error",
        legend_cell_align={left},
        legend_pos="north west",
        ymax=15e-2,
        xmax=100,
    },
    PlotInc({lineopts..., color=color_nominal, style="solid"}, Coordinates(1:100, res_lqr_perf[:errors_nominal])),
    PlotInc({lineopts..., color=color_eDMD, style="solid"}, Coordinates(1:100, res_lqr_perf[:errors_eDMD_projected])),
    PlotInc({lineopts..., color=color_jDMD, style="solid"}, Coordinates(1:100, res_lqr_perf[:errors_jDMD_projected])),
    PlotInc({lineopts..., color=color_eDMD, style="dashed"}, Coordinates(1:100, res_lqr_perf[:errors_eDMD])),
    PlotInc({lineopts..., color=color_jDMD, style="dashed"}, Coordinates(1:100, res_lqr_perf[:errors_jDMD])),
    # Legend(["nominal", "eDMD (projected)", "jDMD (projected)", "eDMD (lifted)", "jDMD (lifted)"])
)
#display(p_lqr_perf)
# pgfsave(joinpath(Problems.FIGDIR, "rex_planar_quadrotor_lqr_stabilization_performance.tikz"), 
#     p_lqr_perf, include_preamble=false)

p_lqr_window = @pgf Axis(
    {
        xmajorgrids,
        ymajorgrids,
        xlabel = "Fraction of Training Range",
        ylabel = "Stabilization error",
        legend_pos = "north west",
        ymax = 20,
    },
    PlotInc({lineopts..., color=color_eDMD}, Coordinates(percentages, res_lqr_window[:error_eDMD_projected_unreg])),
    PlotInc({lineopts..., color="teal"}, Coordinates(percentages, res_lqr_window[:error_eDMD_projected])),
    PlotInc({lineopts..., color=color_jDMD}, Coordinates(percentages, res_lqr_window[:error_jDMD_projected])),
    PlotInc({lineopts..., color="purple"}, Coordinates(percentages, res_lqr_window[:error_jDMD_projected2])),

    # Legend(["eDMD" * L"(\lambda = 0.0)", "eDMD" * L"(\lambda = 0.1)", "jDMD" * L"(\lambda = 10^{-5})", "jDMD" * L"(\lambda = 0.1)"])
)
# pgfsave(joinpath(Problems.FIGDIR, "rex_planar_quadrotor_lqr_error_by_training_window.tikz"), p_lqr_window, include_preamble=false)

p_lqr_equilibrium = @pgf Axis(
    {
        xmajorgrids,
        ymajorgrids,
        xlabel = "Equilibrium offset",
        ylabel = "Stabilization error",
        legend_pos = "north west",
        ymax = 200,
        
    },
    PlotInc({no_marks, color=color_eDMD, thick}, Coordinates(distances, res_equilibrium[:error_eDMD_projected_unreg])),
    PlotInc({lineopts..., color=color_eDMD, line_width=2}, Coordinates(distances, res_equilibrium[:error_eDMD_projected])),
    PlotInc({no_marks, color=color_jDMD, thick}, Coordinates(distances, res_equilibrium[:error_jDMD_projected])),
    PlotInc({lineopts..., color=color_jDMD, line_width=2}, Coordinates(distances, res_equilibrium[:error_jDMD_projected2])),

    # Legend(["eDMD" * L"(\lambda = 0.0)", "eDMD" * L"(\lambda = 0.1)", "jDMD" * L"(\lambda = 10^{-5})", "jDMD" * L"(\lambda = 0.1)"])
)
pgfsave(joinpath(Problems.FIGDIR, "rex_planar_quadrotor_lqr_error_by_equilibrium_change.tikz"), p_lqr_equilibrium, include_preamble=false)

p_mpc = @pgf Axis(
    {
        xmajorgrids,
        ymajorgrids,
        xlabel="Percent of samples",
        # ylabel="Tracking error",
        legend_cell_align={left},
        legend_pos="outer north east",
        ymax=15e-2,
        xmax=100,
    },
    PlotInc({lineopts..., color=color_nominal, style="solid"}, Coordinates(1:100, res_mpc_tracking[:errors_nominal])),
    PlotInc({lineopts..., color=color_eDMD, style="solid"}, Coordinates(1:100, res_mpc_tracking[:errors_eDMD_projected])),
    PlotInc({lineopts..., color=color_jDMD, style="solid"}, Coordinates(1:100, res_mpc_tracking[:errors_jDMD_projected])),
    PlotInc({lineopts..., color=color_eDMD, style="dashed"}, Coordinates(1:100, res_mpc_tracking[:errors_eDMD])),
    PlotInc({lineopts..., color=color_jDMD, style="dashed"}, Coordinates(1:100, res_mpc_tracking[:errors_jDMD])),
    Legend(["nominal", "eDMD (projected)", "jDMD (projected)", "eDMD (lifted)", "jDMD (lifted)"])
)
# display(p_mpc)
# pgfsave(joinpath(Problems.FIGDIR, "rex_planar_quadrotor_mpc_stabilization_performance.tikz"), 
    # p_mpc, include_preamble=false)