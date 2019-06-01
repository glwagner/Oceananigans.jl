using .TurbulenceClosures

mutable struct Model{A<:Architecture, G, VV, TT, PP, BCS, TG, PS, SF, TC, TD, T}
              arch :: A                  # Computer `Architecture` on which `Model` is run.
              grid :: G                  # Grid of physical points on which `Model` is solved.
             clock :: Clock{T}           # Tracks iteration number and simulation time of `Model`.
               eos :: LinearEquationOfState{T}# Defines relationship between temperature,  salinity, and 
                                         # buoyancy in the Boussinesq vertical momentum equation.
         constants :: PlanetaryConstants{T} # Set of physical constants, inc. gravitational acceleration.
        velocities :: VV # Container for velocity fields `u`, `v`, and `w`.
           tracers :: TT # Container for tracer fields.
         pressures :: PP # Container for hydrostatic and nonhydrostatic pressure.
           #forcing                       # Container for forcing functions defined by the user
           closure :: TC                 # Diffusive 'turbulence closure' for all model fields
    boundary_conditions :: BCS # Container for 3d bcs on all fields.
                 G :: TG # Container for right-hand-side of PDE that governs `Model`
                Gp :: TG # RHS at previous time-step (for Adams-Bashforth time integration)
    poisson_solver :: PS # ::PoissonSolver or ::PoissonSolverGPU
       stepper_tmp :: SF # Temporary fields used for the Poisson solver.
         turbdiffs :: TD
    output_writers :: Array{OutputWriter, 1} # Objects that write data to disk.
       diagnostics :: Array{Diagnostic, 1}   # Objects that calc diagnostics on-line during simulation.
end


"""
    Model(; kwargs...)

Construct a basic `Oceananigans.jl` model.
"""
function Model(;
    # Model resolution and domain size
             N,
             L,
    # Model architecture and floating point precision
          arch = CPU(),
    float_type = Float64,
          grid = RegularCartesianGrid(float_type, N, L),
    # Isotropic transport coefficients (exposed to `Model` constructor for convenience)
             ν = 1.05e-6,
             κ = 1.43e-7,
       closure = ConstantIsotropicDiffusivity(float_type, ν=ν, κ=κ),
    # Fluid and physical parameters
     constants = Earth(float_type),
           eos = LinearEquationOfState(float_type),
    # Forcing and boundary conditions for (u, v, w, T, S)
       #forcing = Forcing(nothing, nothing, nothing, nothing, nothing),
    boundary_conditions = ModelBoundaryConditions(),
    # Output and diagonstics
    output_writers = OutputWriter[],
       diagnostics = Diagnostic[],
             clock = Clock{float_type}(0, 0)
)

    arch == GPU() && !HAVE_CUDA && throw(ArgumentError("Cannot create a GPU model. No CUDA-enabled GPU was detected!"))

    # Initialize fields, including source terms and temporary variables.
      velocities = VelocityFields(arch, grid)
         tracers = TracerFields(arch, grid)
       pressures = PressureFields(arch, grid)
               G = SourceTerms(arch, grid)
              Gp = SourceTerms(arch, grid)
     stepper_tmp = StepperTemporaryFields(arch, grid)
       turbdiffs = TurbulentDiffusivities(arch, grid, closure)

    # Initialize Poisson solver.
    poisson_solver = PoissonSolver(arch, grid)

    # Set the default initial condition
    initialize_with_defaults!(eos, tracers, velocities, G, Gp)

    #Model(arch, grid, clock, eos, constants,
    #      velocities, tracers, pressures, forcing, closure, boundary_conditions,
    Model(arch, grid, clock, eos, constants,
          velocities, tracers, pressures, closure, boundary_conditions,
          G, Gp, poisson_solver, stepper_tmp, turbdiffs, output_writers, diagnostics)
end

arch(model::Model{A}) where A <: Architecture = A
float_type(m::Model) = eltype(model.grid)
add_bcs!(model::Model; kwargs...) = add_bcs(model.boundary_conditions; kwargs...)

function initialize_with_defaults!(eos, tracers, sets...)

    # Default tracer initial condition is deteremined by eos.
    tracers.S.data .= eos.S₀
    tracers.T.data .= eos.T₀

    # Set all further fields to 0
    for set in sets
        for fldname in propertynames(set)
            fld = getproperty(set, fldname)
            fld.data .= 0 # promotes to eltype of fld.data
        end
    end
    
    return nothing
end
