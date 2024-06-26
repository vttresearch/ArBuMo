#=
    process_node.jl

Contains functions for processing the properties of lumped-capacitance thermal nodes.
=#

"""
    create_building_node_network(
        archetype::Object,
        fabrics::Object,
        systems::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        loads::LoadsData;
        mod::Module=@__MODULE__,
    )

Map all `archetype` `building_nodes` to their [`BuildingNodeData`](@ref)s.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, loops over the `building_fabrics__building_node` and
`building_systems__building_node` relationships for the desired `archetype`,
and collects all the `building_node`s and [`BuildingNodeData`](@ref)s
into a [`BuildingNodeNetwork`](@ref) dictionary.
"""
function create_building_node_network(
    archetype::Object,
    fabrics::Object,
    systems::Object,
    scope::ScopeData,
    envelope::EnvelopeData,
    loads::LoadsData;
    mod::Module=@__MODULE__,
)
    merge(
        Dict{Object,BuildingNodeData}(
            node => BuildingNodeData(archetype, node, scope, envelope, loads; mod=mod) for
            node in mod.building_fabrics__building_node(building_fabrics=fabrics)
        ),
        Dict{Object,BuildingNodeData}(
            node => BuildingNodeData(archetype, node, scope, envelope, loads; mod=mod) for
            node in mod.building_systems__building_node(building_systems=systems)
        ),
    )::BuildingNodeNetwork
end


"""
    process_building_node(
        archetype::Object,
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        loads::LoadsData;
        mod::Module=@__MODULE__,
    )

Calculates the properties of a `node` using the provided `archetype`, `scope`, `envelope`, and `loads` data.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Aggregates the properties of the allocated structures according to their
[structure\\_type\\_weight](@ref) parameters. The fenestration and ventilation
properties are allocated based on [is\\_internal](@ref). Division of internal
heat gains and solar heat gains between the interior air and the different
structure types is based on the the relative surface areas of the different
structure types and their [structure\\_type\\_weight](@ref)s, as well as the
[internal\\_heat\\_gain\\_convective\\_fraction](@ref) for controlling the
assumed convective vs radiative fractions of the internal gains. Solar gains
through the windows are divided between the interior air and structures similar
to internal heat gains, but use the [solar\\_heat\\_gain\\_convective\\_fraction](@ref)
parameter for their convective vs radiative fraction instead.
Solar heat gains through the opaque parts of the building envelope are applied
entirely to the structures, as are envelope radiative sky heat losses.

Essentially, this function performs the following steps:
1. Fetch user defined thermal mass, self-discharge, temperature set-point, and heat transfer coefficient parameters.
2. Calculate the thermal mass on the `node` using [`calculate_interior_air_and_furniture_thermal_mass`](@ref) and [`calculate_structural_thermal_mass`](@ref).
3. Calculate the total heat transfer coefficient between the structures on this `node` and the interior air using [`calculate_structural_interior_heat_transfer_coefficient`](@ref).
4. Calculate the total heat transfer coefficient between the structures on this `node` and the ambient air using [`calculate_structural_exterior_heat_transfer_coefficient`](@ref).
5. Calculate the total heat transfer coefficient between the structures on this `node` and the ground using [`calculate_structural_ground_heat_transfer_coefficient`](@ref).
6. Calculate the total heat transfer coefficient through windows for this `node` using [`calculate_window_heat_transfer_coefficient`](@ref).
7. Calculate the total heat transfer coefficient of ventilation and infiltration on this `node` with and without ventilation heat recovery using [`calculate_ventilation_and_infiltration_heat_transfer_coefficients`](@ref).
8. Calculate the total heat transfer coefficient of thermal bridges for this `node` using [`calculate_total_thermal_bridge_heat_transfer_coefficient`](@ref).
9. Fetch domestic hot water demand from `loads` for this `node`.
10. Calculate the convective internal heat gains on this `node` using [`calculate_convective_internal_heat_gains`](@ref).
11. Calculate the radiative internal heat gains on this `node` using [`calculate_radiative_internal_heat_gains`](@ref).
12. Return all the pieces necessary for constructing the [`BuildingNodeData`](@ref) for this `node`.

**NOTE! Linear thermal bridges are assumed to bypass any potential structural lumped-capacitance nodes,
and apply directly to the heat transfer coefficient between the interior air and the ambient air!**
**NOTE! Currently, radiative internal gains are lost through the windows
in the building envelope.**
"""
function process_building_node(
    archetype::Object,
    node::Object,
    scope::ScopeData,
    envelope::EnvelopeData,
    loads::LoadsData;
    mod::Module=@__MODULE__,
)
    # Check if node is primary interior node or dhw node
    is_interior_node = mod.is_interior_node(building_node=node)
    is_dhw_node = mod.is_domestic_hot_water_node(building_node=node)

    # Fetch user defined thermal mass components of the node.
    thermal_mass_base_J_K = mod.effective_thermal_mass_base_J_K(building_node=node)
    thermal_mass_gfa_scaled_J_K =
        scope.average_gross_floor_area_m2_per_building *
        mod.effective_thermal_mass_gfa_scaling_J_m2K(building_node=node)

    # Fetch user-defined self-discharge rates.
    self_discharge_base_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        mod.self_discharge_rate_base_W_K(building_node=node)
    self_discharge_gfa_scaled_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        scope.average_gross_floor_area_m2_per_building *
        mod.self_discharge_rate_gfa_scaling_W_m2K(building_node=node)

    # Set point overrides for indoor air temperature.
    if (
        is_interior_node &&
        !isnothing(
            mod.indoor_air_cooling_set_point_override_K(building_archetype=archetype),
        )
    )
        cooling_set_point_K =
            mod.indoor_air_cooling_set_point_override_K(building_archetype=archetype)
    else
        cooling_set_point_K = mod.cooling_set_point_K(building_node=node)
    end
    if (
        is_interior_node &&
        !isnothing(
            mod.indoor_air_heating_set_point_override_K(building_archetype=archetype),
        )
    )
        heating_set_point_K =
            mod.indoor_air_heating_set_point_override_K(building_archetype=archetype)
    else
        heating_set_point_K = mod.heating_set_point_K(building_node=node)
    end

    # Determine the valid nodes for heat transfer coefficients
    fabrics = only(mod.building_archetype__building_fabrics(building_archetype=archetype))
    systems = only(mod.building_archetype__building_systems(building_archetype=archetype))
    valid_nodes = vcat(
        mod.building_fabrics__building_node(building_fabrics=fabrics),
        mod.building_systems__building_node(building_systems=systems),
    )
    # Fetch the user-defined heat transfer coefficients for the valid nodes
    heat_transfer_coefficients_base_W_K = Dict(
        n => mod.heat_transfer_coefficient_base_W_K(
            building_node1=node,
            building_node2=n,
        ) for
        n in mod.building_node__building_node(building_node1=node) if n in valid_nodes
    )
    heat_transfer_coefficients_gfa_scaled_W_K = Dict(
        n =>
            scope.average_gross_floor_area_m2_per_building *
            mod.heat_transfer_coefficient_gfa_scaling_W_m2K(
                building_node1=node,
                building_node2=n,
            ) for
        n in mod.building_node__building_node(building_node1=node) if n in valid_nodes
    )

    # Calculate interior air and structural thermal masses.
    thermal_mass_interior_air_and_furniture_J_K =
        calculate_interior_air_and_furniture_thermal_mass(
            archetype,
            scope,
            is_interior_node;
            mod=mod,
        )
    thermal_mass_structures_J_K =
        calculate_structural_thermal_mass(node, scope, envelope; mod=mod)

    # Calculate the heat transfer coefficients of the included structures.
    heat_transfer_coefficient_structures_interior_W_K =
        calculate_structural_interior_heat_transfer_coefficient(
            node,
            scope,
            envelope,
            is_interior_node;
            mod=mod,
        )
    heat_transfer_coefficient_structures_exterior_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        calculate_structural_exterior_heat_transfer_coefficient(
            node,
            scope,
            envelope,
            is_interior_node;
            mod=mod,
        )
    heat_transfer_coefficient_structures_ground_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        calculate_structural_ground_heat_transfer_coefficient(
            archetype,
            node,
            scope,
            envelope;
            mod=mod,
        )

    # Calculate the heat transfer coefficients for fenestration, ventilation, and thermal bridges
    heat_transfer_coefficient_windows_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        calculate_window_heat_transfer_coefficient(scope, envelope, is_interior_node)
    heat_transfer_coefficient_ventilation_and_infiltration_W_K,
    heat_transfer_coefficient_ventilation_and_infiltration_W_K_HRU_bypass =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) .*
        calculate_ventilation_and_infiltration_heat_transfer_coefficients(
            archetype,
            scope,
            is_interior_node;
            mod=mod,
        )
    heat_transfer_coefficient_thermal_bridges_W_K =
        mod.energy_efficiency_override_multiplier(building_archetype=archetype) *
        calculate_total_thermal_bridge_heat_transfer_coefficient(
            archetype,
            scope,
            envelope,
            is_interior_node;
            mod=mod,
        )

    # Fetch the DHW demand for the node.
    if is_dhw_node
        domestic_hot_water_demand_W =
            loads.domestic_hot_water_demand_W
    else
        domestic_hot_water_demand_W = 0.0
    end

    # Calculate the internal heat gains for the node, first for internal air and then structures.
    internal_heat_gains_air_W = calculate_convective_internal_heat_gains(
        archetype,
        loads,
        is_interior_node;
        mod=mod,
    )
    internal_heat_gains_structures_W =
        calculate_radiative_internal_heat_gains(archetype, node, envelope, loads; mod=mod)

    # Return all the stuff in the correct order.
    return heating_set_point_K,
    cooling_set_point_K,
    thermal_mass_base_J_K,
    thermal_mass_gfa_scaled_J_K,
    thermal_mass_interior_air_and_furniture_J_K,
    thermal_mass_structures_J_K,
    mod.permitted_temperature_deviation_positive_K(building_node=node),
    mod.permitted_temperature_deviation_negative_K(building_node=node),
    self_discharge_base_W_K,
    self_discharge_gfa_scaled_W_K,
    heat_transfer_coefficients_base_W_K,
    heat_transfer_coefficients_gfa_scaled_W_K,
    heat_transfer_coefficient_structures_interior_W_K,
    heat_transfer_coefficient_structures_exterior_W_K,
    heat_transfer_coefficient_structures_ground_W_K,
    heat_transfer_coefficient_windows_W_K,
    heat_transfer_coefficient_ventilation_and_infiltration_W_K,
    heat_transfer_coefficient_ventilation_and_infiltration_W_K_HRU_bypass,
    heat_transfer_coefficient_thermal_bridges_W_K,
    domestic_hot_water_demand_W,
    internal_heat_gains_air_W,
    internal_heat_gains_structures_W,
    is_interior_node,
    is_dhw_node
end


"""
    calculate_interior_air_and_furniture_thermal_mass(
        archetype::Object,
        scope::ScopeData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )

Calculate the effective thermal mass of interior air and furniture on `node` in [J/K].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, the calculation is based on the gross-floor area [m2] of the archetype
building and the assumed effective thermal capacity of interior air and furniture.
```math
C_\\text{int,n} = c_\\text{int,gfa} A_\\text{gfa}
```
where `c_int,gfa` is the assumed
[effective\\_thermal\\_capacity\\_of\\_interior\\_air\\_and\\_furniture\\_J\\_m2K](@ref),
and `A_gfa` is the gross-floor area of the building.
"""
function calculate_interior_air_and_furniture_thermal_mass(
    archetype::Object,
    scope::ScopeData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    is_interior_node ?
    scope.average_gross_floor_area_m2_per_building *
    mod.effective_thermal_capacity_of_interior_air_and_furniture_J_m2K(
        building_archetype=archetype,
    ) : 0.0
end


"""
    calculate_structural_thermal_mass(
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData;
        mod::Module=@__MODULE__,
    )

Calculate the effective thermal mass of the structures on `node` in [J/K].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, sums the total effective thermal mass of the structures
attributed to this node, accounting for their assigned weights.
```math
C_\\text{n,str} = \\sum_{\\text{st} \\in n} w_\\text{n,st} c_\\text{st} A_\\text{st}
```
where `st` is the [structure\\_type](@ref) and `n` is the [building\\_node](@ref),
`w_n,st` is the [structure\\_type\\_weight](@ref) of the structure `st` on this node,
`c_st` is the [effective\\_thermal\\_mass\\_J\\_m2K](@ref) of the structure,
and `A_st` is the surface area of the structure.
"""
function calculate_structural_thermal_mass(
    node::Object,
    scope::ScopeData,
    envelope::EnvelopeData;
    mod::Module=@__MODULE__,
)
    reduce(
        +,
        scope.structure_data[st].effective_thermal_mass_J_m2K *
        getfield(envelope, st.name).surface_area_m2 *
        mod.structure_type_weight(building_node=node, structure_type=st) for
        st in mod.building_node__structure_type(building_node=node);
        init=0,
    )
end


"""
    calculate_structural_interior_heat_transfer_coefficient(
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )

Calculate the total interior heat transfer coefficient of the structures in `node` in [W/K].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, initializes the total heat transfer coefficient between
the interior air node and the node containing the structures.
For internal structures, the U-values for both the interior and
*exterior* surface are used, effectively accounting for both sides of interior
structures. If an external structure is lumped together with the
interior air node, it's internal heat transfer coefficient is attributed to its
exterior heat transfer instead, *but using this feature is not recommended*!
```math
H_\\text{int,n} = \\begin{cases}
\\sum_{\\text{st} \\in n} w_\\text{n,st} U_\\text{int,st} A_\\text{st} \\qquad \\text{st} \\notin \\text{internal structures} \\\\
\\sum_{\\text{st} \\in n} w_\\text{n,st} ( U_\\text{int,st} + U_\\text{ext,st} ) A_\\text{st} \\qquad \\text{st} \\in \\text{internal structures}
\\end{cases}
```
where `st` is the [structure\\_type](@ref),
`w_n,st` is the [structure\\_type\\_weight](@ref) of the structure `st` on node `n`,
`U_int,st` is the [internal\\_U\\_value\\_to\\_structure\\_W\\_m2K](@ref) of structure `st`,
and `A_st` is the surface area of structure `st`.
A structure `st` is considered internal if the [is\\_internal](@ref) flag is true.
"""
function calculate_structural_interior_heat_transfer_coefficient(
    node::Object,
    scope::ScopeData,
    envelope::EnvelopeData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    is_interior_node ? 0.0 :
    sum(
        (
            scope.structure_data[st].internal_U_value_to_structure_W_m2K + (
                mod.is_internal(structure_type=st) ?
                scope.structure_data[st].external_U_value_to_ambient_air_W_m2K : 0
            )
        ) *
        getfield(envelope, st.name).surface_area_m2 *
        mod.structure_type_weight(building_node=node, structure_type=st) for
        st in mod.building_node__structure_type(building_node=node);
        init=0,
    )
end


"""
    calculate_structural_exterior_heat_transfer_coefficient(
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )

Calculate the total exterior heat transfer coefficient of the structures in `node` in [W/K].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, calculates the total heat transfer coefficient between
the ambient air and the node containing the structures.
Internal structures have no exterior heat transfer coefficient,
as they are assumed to not be part of the building envelope.
If an external structure is lumped together with the
interior air node, it's internal heat transfer coefficient is attributed to its
exterior heat transfer as well, *but using this feature is not recommended*!
```math
H_\\text{ext,n} = \\sum_{\\text{st} \\in n} w_\\text{n,st} \\left( \\frac{1}{U_\\text{ext,st}} + \\frac{w_{int,n}}{U_\\text{int,st}} \\right)^{-1} A_\\text{st}
```
where `st` is the [structure\\_type](@ref) and `n` is the [building\\_node](@ref),
`w_n,st` is the [structure\\_type\\_weight](@ref) of the structure `st` on this node,
`U_ext,st` is the [external\\_U\\_value\\_to\\_ambient\\_air\\_W\\_m2K](@ref) of structure `st`,
`w_int,n` is the [is\\_interior\\_node](@ref) boolean flag of this node,
`U_int,st` is the [internal\\_U\\_value\\_to\\_structure\\_W\\_m2K](@ref) of structure `st`,
and `A_st` is the surface area of structure `st`.
"""
function calculate_structural_exterior_heat_transfer_coefficient(
    node::Object,
    scope::ScopeData,
    envelope::EnvelopeData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    sum(
        1 / (
            1 / scope.structure_data[st].external_U_value_to_ambient_air_W_m2K +
            is_interior_node / # If an external structure is lumped together with air, it's internal heat coefficient adds to the external heat transfer.
            scope.structure_data[st].internal_U_value_to_structure_W_m2K
        ) *
        getfield(envelope, st.name).surface_area_m2 *
        mod.structure_type_weight(building_node=node, structure_type=st) for
        st in mod.building_node__structure_type(building_node=node) if
        !(mod.is_internal(structure_type=st));
        init=0,
    )
end


"""
    calculate_structural_ground_heat_transfer_coefficient(
        archetype::Object,
        node::Object,
        scope::ScopeData,
        envelope::EnvelopeData;
        mod::Module=@__MODULE__,
    )

Calculate the total ground heat transfer coefficient of the structures in `node` in [W/K].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, calculates the total heat transfer coefficient between
the ground and the node containing the structures according to the simplified
method proposed by K.Kissock in:
`Simplified Model for Ground Heat Transfer from Slab-on-Grade Buildings, (c) 2013 ASHRAE`
```math
H_\\text{grn,n} = \\left( 1 + \\frac{d_\\text{frame}^2}{A_\\text{bf}} \\right) \\sum_{\\text{st} \\in n} w_\\text{n,st} U_\\text{grn,st} A_\\text{st}
```
where `d_frame` is the assumed [building\\_frame\\_depth\\_m](@ref),
`A_bf` is the area according to [`calculate_base_floor_dimensions`](@ref),
`st` is the [structure\\_type](@ref) and `n` is the [building\\_node](@ref),
`w_n,st` is the [structure\\_type\\_weight](@ref) of the structure `st` on this node,
`U_grn,st` is the [external\\_U\\_value\\_to\\_ground\\_W\\_m2K](@ref) of structure `st`,
and `A_st` is the surface area of structure `st`.
Note that the correction factor `C = (length + width) / length = 1 + d_frame^2 / A_bf`
in the above equation assumes that `d_frame < A_bf / d_frame`.
If `d_frame > A_bf / d_frame`, the correction term becomes `1 + A_bf / d_frame^2` instead.
"""
function calculate_structural_ground_heat_transfer_coefficient(
    archetype::Object,
    node::Object,
    scope::ScopeData,
    envelope::EnvelopeData;
    mod::Module=@__MODULE__,
)
    (
        1 + min(
            mod.building_frame_depth_m(building_archetype=archetype)^2 /
            envelope.base_floor.surface_area_m2,
            envelope.base_floor.surface_area_m2 /
            mod.building_frame_depth_m(building_archetype=archetype)^2,
        )
    ) * reduce(
        +,
        scope.structure_data[st].external_U_value_to_ground_W_m2K *
        getfield(envelope, st.name).surface_area_m2 *
        mod.structure_type_weight(building_node=node, structure_type=st) for
        st in mod.building_node__structure_type(building_node=node);
        init=0,
    )
end


"""
    calculate_window_heat_transfer_coefficient(
        scope::ScopeData,
        envelope::EnvelopeData,
        is_interior_node::Bool,
    )

Calculate the total heat transfer coefficient for windows.

Windows are assumed to transfer heat directly between the indoor air and the ambient air.
```math
H_\\text{w,n} = U_\\text{w} A_\\text{w}
```
where `U_w` is the [window\\_U\\_value\\_W\\_m2K](@ref),
and `A_w` is the surface area of the windows.
Note that heat transfer through windows is only applied to the
[is\\_interior\\_node](@ref) node.
"""
function calculate_window_heat_transfer_coefficient(
    scope::ScopeData,
    envelope::EnvelopeData,
    is_interior_node::Bool,
)
    is_interior_node ? scope.window_U_value_W_m2K * envelope.window.surface_area_m2 : 0.0
end


"""
    calculate_ventilation_and_infiltration_heat_transfer_coefficients(
        archetype::Object,
        scope::ScopeData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )
    
Calculate ventilation and infiltration heat transfer coefficients with and without HRU.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Ventilation and infiltration are assumed to transfer heat directly between the
interior and ambient air. Loosely based on EN ISO 52016-1:2017 6.5.10.1.
```math
H_\\text{ven,n} = A_\\text{gfa} h_\\text{room} \\rho_\\text{air} \\frac{ (1 - \\eta_\\text{hru}) r_\\text{ven} + r_\\text{inf}}{3600}
```
where `A_gfa` is the gross-floor area of the building,
`h_room` is the assumed [room\\_height\\_m](@ref),
`ρ_air` is the assumed [volumetric\\_heat\\_capacity\\_of\\_interior\\_air\\_J\\_m3K](@ref),
`η_hru` is the [HRU\\_efficiency](@ref) *(heat recovery unit)*,
`r_ven` is the [ventilation\\_rate\\_1\\_h](@ref),
and `r_inf` is the [infiltration\\_rate\\_1\\_h](@ref).
The division by 3600 accounts for the unit conversion from J to Wh.

Note that ventilation and infiltration heat transfer is only applied to the
[is\\_interior\\_node](@ref) node.
"""
function calculate_ventilation_and_infiltration_heat_transfer_coefficients(
    archetype::Object,
    scope::ScopeData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    is_interior_node ?
    Tuple(
        scope.average_gross_floor_area_m2_per_building *
        mod.room_height_m(building_archetype=archetype) *
        mod.volumetric_heat_capacity_of_interior_air_J_m3K(building_archetype=archetype) /
        3600 * (scope.ventilation_rate_1_h * (1 - hru) + scope.infiltration_rate_1_h) for
        hru in (scope.HRU_efficiency, 0)
    ) : (0.0, 0.0)
end


"""
    calculate_total_thermal_bridge_heat_transfer_coefficient(
        archetype::Object,
        scope::ScopeData,
        envelope::EnvelopeData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )

Calculate total thermal bridge heat transfer coefficient.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Thermal bridges are assumed to bypass the temperature node within the structure,
and act as direct heat transfer between the indoor air and ambient conditions.
```math
H_{\\Psi,n} = \\left( \\Delta U_\\text{w,tb} A_w + \\sum_\\text{st} \\left[ l_\\text{st} \\Psi_\\text{st} \\right] \\right)
```
where `ΔU_w,tb` is the [window\\_area\\_thermal\\_bridge\\_surcharge\\_W\\_m2K](@ref),
`A_w` is the window surface area based on [`calculate_window_dimensions`](@ref),
`st` is the [structure\\_type](@ref),
`l_st` is the length of the linear thermal bridge of structure `st`,
and `Ψ_st` is the [linear\\_thermal\\_bridges\\_W\\_mK](@ref).

Note that thermal bridge heat transfer is only applied to the
[is\\_interior\\_node](@ref) node.
"""
function calculate_total_thermal_bridge_heat_transfer_coefficient(
    archetype::Object,
    scope::ScopeData,
    envelope::EnvelopeData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    is_interior_node ?
    (
        mod.window_area_thermal_bridge_surcharge_W_m2K(building_archetype=archetype) *
        envelope.window.surface_area_m2 + reduce(
            +,
            scope.structure_data[st].linear_thermal_bridges_W_mK *
            getfield(envelope, st.name).linear_thermal_bridge_length_m for
            st in mod.structure_type();
            init=0,
        )
    ) : 0.0
end


"""
    calculate_convective_internal_heat_gains(
        archetype::Object,
        loads::LoadsData,
        is_interior_node::Bool;
        mod::Module=@__MODULE__,
    )

Calculate the convective internal heat gains on the `node` in [W].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, takes the given internal heat gain profile in `loads` and
multiplies it with the share of interior air on this `node` as well as the
assumed convective fraction of internal heat gains.
```math
\\Phi_\\text{int,conv,n} = f_\\text{int,conv} \\Phi_\\text{int}
```
where `f_int,conv` is the assumed [internal\\_heat\\_gain\\_convective\\_fraction](@ref),
and `Φ_int` are the total internal heat gains of the building.
See [`calculate_total_internal_heat_loads`](@ref) for how the total
internal heat loads are calculated.

Note that convective internal heat gains are only applied to the
[is\\_interior\\_node](@ref) node.
"""
function calculate_convective_internal_heat_gains(
    archetype::Object,
    loads::LoadsData,
    is_interior_node::Bool;
    mod::Module=@__MODULE__,
)
    is_interior_node ?
    loads.internal_heat_gains_W *
    mod.internal_heat_gain_convective_fraction(building_archetype=archetype) : 0.0
end


"""
    calculate_radiative_internal_heat_gains(
        archetype::Object,
        node::Object,
        envelope::EnvelopeData,
        loads::LoadsData;
        mod::Module=@__MODULE__,
    )

Calculate the radiative internal heat gains on the `node` in [W].

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Essentially, takes the given internal heat gain profile in `loads`
and multiplies it with the assumed radiative fraction of internal heat gains.
The radiative heat gains are assumed to be distributed across the structures 
simply based on their relative surface areas.
Note that currently, radiative internal heat gains are partially lost through windows!
```math
\\Phi_\\text{int,rad,n} = (1 - f_\\text{int,conv}) \\frac{\\sum_{\\text{st} \\in n} w_\\text{n,st} A_\\text{st}}{\\sum_{\\text{st}} A_\\text{st}} \\Phi_\\text{int}
```
where `f_int,conv` is the assumed [internal\\_heat\\_gain\\_convective\\_fraction](@ref),
`st` is the [structure\\_type](@ref) and `n` is this [building\\_node](@ref),
`w_n,st` is the [structure\\_type\\_weight](@ref) of the structure `st` on this node,
`A_st` is the surface area of structure `st`,
and `Φ_int` are the total internal heat gains of the building.
See [`calculate_total_internal_heat_loads`](@ref) for how the total
internal heat loads are calculated.
"""
function calculate_radiative_internal_heat_gains(
    archetype::Object,
    node::Object,
    envelope::EnvelopeData,
    loads::LoadsData;
    mod::Module=@__MODULE__,
)
    loads.internal_heat_gains_W *
    (1 - mod.internal_heat_gain_convective_fraction(building_archetype=archetype)) *
    sum(
        mod.structure_type_weight(building_node=node, structure_type=st) *
        getfield(envelope, st.name).surface_area_m2 / envelope.total_structure_area_m2 for
        st in mod.building_node__structure_type(building_node=node);
        init=0,
    )
end
