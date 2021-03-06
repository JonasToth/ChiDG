module type_chidg
#include <messenger.h>
    use mod_constants,              only: NFACES, ZERO, ONE, TWO, NO_ID, OUTPUT_RES
    use mod_equations,              only: register_equation_builders
    use mod_operators,              only: register_operators
    use mod_models,                 only: register_models
    use mod_bc,                     only: register_bcs
    use mod_function,               only: register_functions
    use mod_prescribed_mesh_motion_function, only: register_prescribed_mesh_motion_functions
    use mod_grid,                   only: initialize_grid
    use type_svector,               only: svector_t
    use mod_string,                 only: get_file_extension, string_t, get_file_prefix

    use type_chidg_data,            only: chidg_data_t
    use type_chidg_vector,          only: chidg_vector_t, sub_chidg_vector_chidg_vector
    use type_time_integrator,       only: time_integrator_t
    use mod_time,                   only: time_manager_global
    use type_linear_solver,         only: linear_solver_t
    use type_nonlinear_solver,      only: nonlinear_solver_t
    use type_preconditioner,        only: preconditioner_t
    use type_meshdata,              only: meshdata_t
    use type_domain_patch_data,     only: domain_patch_data_t
    use type_bc_state_group,        only: bc_state_group_t
    use type_bc_state,              only: bc_state_t
    use type_dict,                  only: dict_t
    use type_domain_connectivity,   only: domain_connectivity_t
    use type_partition,             only: partition_t

    use mod_time_integrators,       only: create_time_integrator
    use mod_linear_solver,          only: create_linear_solver
    use mod_nonlinear_solver,       only: create_nonlinear_solver
    use mod_preconditioner,         only: create_preconditioner

    use mod_communication,          only: establish_neighbor_communication, &
                                          establish_chimera_communication
    use mod_chidg_mpi,              only: chidg_mpi_init, chidg_mpi_finalize,   &
                                          IRANK, NRANK, ChiDG_COMM

    use mod_hdfio
    use mod_hdf_utilities
    use mod_tecio,                  only: write_tecio
    use mod_partitioners,           only: partition_connectivity, send_partitions, &
                                          recv_partition
    use mpi_f08
    use mod_io


    use type_prescribed_mesh_motion_domain_data,        only: prescribed_mesh_motion_domain_data_t
    use type_prescribed_mesh_motion_group_wrapper,        only: prescribed_mesh_motion_group_wrapper_t
    implicit none









    !>  The ChiDG Environment container
    !!
    !!  Contains: 
    !!      - data: mesh, bcs, equations for each domain.
    !!      - a time integrator
    !!      - a nonlinear solver
    !!      - a linear solver
    !!      - a preconditioner
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !-----------------------------------------------------------------------------------------
    type, public :: chidg_t

        ! Auxiliary ChiDG environment that can be used to solve sub-problems
        type(chidg_t), pointer :: auxiliary_environment

        ! Number of terms in 3D/1D solution basis expansion
        integer(ik)     :: nterms_s     = 0
        integer(ik)     :: nterms_s_1d  = 0

        ! ChiDG Files
        character(:),   allocatable :: grid_file
        character(:),   allocatable :: solution_file_in
        !type(chidg_file_t)        :: solution_file_out

        ! Primary data container. Mesh, equations, bc's, vectors/matrices
        type(chidg_data_t)                          :: data
        
        ! Primary algorithms, selected at run-time
        class(time_integrator_t),   allocatable     :: time_integrator
        class(nonlinear_solver_t),  allocatable     :: nonlinear_solver
        class(linear_solver_t),     allocatable     :: linear_solver
        class(preconditioner_t),    allocatable     :: preconditioner


        ! Partition of the global problem that is owned by the present ChiDG instance.
        type(partition_t)                           :: partition

        logical :: envInitialized = .false.

    contains

        ! Open/Close
        procedure       :: start_up
        procedure       :: shut_down

        ! Initialization
        procedure       :: set
        procedure       :: init

        ! Run
        procedure       :: process
        procedure       :: run
        procedure       :: report

        ! IO
        procedure       :: read_mesh
        procedure       :: read_mesh_grids
        procedure       :: read_mesh_boundary_conditions
        procedure       :: read_prescribedmeshmotions
        procedure       :: write_mesh
        procedure       :: read_fields
        procedure       :: write_fields
        procedure       :: produce_visualization



    end type chidg_t
    !*****************************************************************************************


    interface
        module subroutine auxiliary_driver(chidg,chidg_aux,case,grid_file,aux_file)
            type(chidg_t),  intent(inout)   :: chidg
            type(chidg_t),  intent(inout)   :: chidg_aux
            character(*),   intent(in)      :: case
            character(*),   intent(in)      :: grid_file
            character(*),   intent(in)      :: aux_file
        end subroutine auxiliary_driver
    end interface



contains





    !>  ChiDG Start-Up Activities.
    !!
    !!  activity:
    !!      - 'mpi'         :: Call MPI initialization for ChiDG. This would not be called in 
    !!                         a test, since pFUnit is calling init.
    !!      - 'core'        :: Start-up ChiDG framework. Register functions, equations, 
    !!                         operators, bcs, etc.
    !!      - 'namelist'    :: Start-up Namelist IO
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/18/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine start_up(self,activity,comm)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in)              :: activity
        type(mpi_comm), intent(in), optional    :: comm

        integer(ik) :: ierr, iread

        select case (trim(activity))

            !
            ! Start up MPI
            !
            case ('mpi')
                call chidg_mpi_init(comm)


            !
            ! Start up ChiDG core
            !
            case ('core')


                ! Call environment initialization routines by default on first init call
                if (.not. self%envInitialized ) then
                    call log_init()

                ! Call environment initialization routines by default on first init call
                    ! Order matters here. Functions need to come first. Used by 
                    ! equations and bcs.
                    call register_functions()
                    call register_prescribed_mesh_motion_functions()
                    call register_operators()
                    call register_models()
                    call register_bcs()
                    call register_equation_builders()
                    call initialize_grid()
                    self%envInitialized = .true.

                end if

                ! Allocate an auxiliary ChiDG environment if not already done
                if (.not. associated(self%auxiliary_environment)) then
                    allocate(self%auxiliary_environment, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end if

                self%envInitialized = .true.
                call self%data%time_manager%init()

                !
                ! Initialize global time_manager variable
                !
                call time_manager_global%init()


            !
            ! Start up Namelist
            !
            case ('namelist')

                ! Read data from 'chidg.nml'
                do iread = 0,NRANK-1
                    if ( iread == IRANK ) then
                        call read_input()
                    end if
                    call MPI_Barrier(ChiDG_COMM,ierr)
                end do

                ! Assign from mod_io variables that were read from .nml
                self%grid_file        = gridfile
                self%solution_file_in = solutionfile_in



            case default
                call chidg_signal_one(WARN,'chidg%start_up: Invalid start-up string.',trim(activity))

        end select





    end subroutine start_up
    !*****************************************************************************************







    !>  Any activities that need performed before the program completely terminates.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine shut_down(self,selection)
        class(chidg_t), intent(inout)               :: self
        character(*),   intent(in),     optional    :: selection
        

        if ( present(selection) ) then 
            select case (selection)
                case ('log')
                    call log_finalize()
                case ('mpi')
                    call chidg_mpi_finalize()
                case ('core')   ! All except mpi
                    call log_finalize()
                    call close_hdf()

                    if (allocated(self%time_integrator))  deallocate(self%time_integrator)
                    if (allocated(self%preconditioner))   deallocate(self%preconditioner)
                    if (allocated(self%linear_solver))    deallocate(self%linear_solver)
                    if (allocated(self%nonlinear_solver)) deallocate(self%nonlinear_solver)
                    call self%data%release()


                case default
                    call chidg_signal(FATAL,"chidg%shut_down: invalid shut_down string")
            end select


        else

            call log_finalize()
            call chidg_mpi_finalize()

        end if


    end subroutine shut_down
    !*****************************************************************************************






    !>  ChiDG initialization activities
    !!
    !!  activity:
    !!      - 'communication'   :: Establish local and parallel communication
    !!      - 'chimera'         :: Establish Chimera communication
    !!      - 'finalize'        :: 
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  activity   Initialization activity specification.
    !!
    !-----------------------------------------------------------------------------------------
    recursive subroutine init(self,activity,interpolation,level)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in)              :: activity
        character(*),   intent(in), optional    :: interpolation
        integer(ik),    intent(in), optional    :: level

        character(:),   allocatable :: user_msg
        character(:),   allocatable :: interpolation_in
        integer(ik)                 :: level_in

        select case (trim(activity))

            !
            ! Call all initialization routines.
            !
            case ('all')
                ! geometry
                call self%init('domains',interpolation,level)
                call self%init('bc')

                ! communication
                call self%init('comm - interior')
                call self%init('comm - chimera')

                ! matrix/vector
                call self%init('storage')



            !
            ! Initialize domain data that depend on the solution expansion
            !
            case ('domains')

                user_msg = "chidg%init('domains'): It appears the 'Solution Order' was &
                            not set for the current ChiDG instance. Try calling &
                            'call chidg%set('Solution Order',integer_input=my_order)' &
                            where my_order=1-7 indicates the solution order-of-accuracy."
                if (self%nterms_s == 0) call chidg_signal(FATAL,user_msg)

                ! Default interpolation set = 'Quadrature'
                if (present(interpolation)) then
                    interpolation_in = interpolation
                else 
                    interpolation_in = 'Quadrature'
                end if

                ! Default interpolation level = gq_rule  (from mod_io)
                if (present(level)) then
                    level_in = level
                else
                    level_in = gq_rule
                end if

                call self%data%initialize_solution_domains(interpolation_in,level_in,self%nterms_s)


            !
            ! Initialize boundary condition space
            !
            case ('bc')
                call self%data%initialize_solution_bc()


            !
            ! Initialize communication. Local face communication. Global parallel communication.
            !
            case ('comm - interior')
                call establish_neighbor_communication(self%data%mesh,ChiDG_COMM)


            !
            ! Initialize chimera
            !
            case ('comm - chimera')
                call establish_chimera_communication(self%data%mesh,ChiDG_COMM)


            !
            ! Initialize solver storage initialization: vectors, matrices, etc.
            !
            case ('storage')
                call self%data%initialize_solution_solver()


            !
            ! Allocate components, based on input or default input data
            !
            case ('algorithms')

                !
                ! Test chidg necessary components have been allocated
                !
                if (.not. allocated(self%time_integrator))  call chidg_signal(FATAL,"chidg%time_integrator component was not allocated")
                if (.not. allocated(self%nonlinear_solver)) call chidg_signal(FATAL,"chidg%nonlinear_solver component was not allocated")
                if (.not. allocated(self%linear_solver))    call chidg_signal(FATAL,"chidg%linear_solver component was not allocated")
                if (.not. allocated(self%preconditioner))   call chidg_signal(FATAL,"chidg%preconditioner component was not allocated")

                !
                ! Initialize preconditioner
                !
                call write_line("Initialize: preconditioner...", io_proc=GLOBAL_MASTER)
                call self%preconditioner%init(self%data)
                
                !
                ! Initialize time_integrator
                !
                call write_line("Initialize: time integrator...", io_proc=GLOBAL_MASTER)
                call self%time_integrator%init(self%data)


            case default
                call chidg_signal_one(FATAL,'chidg%init: Invalid initialization string',trim(activity))

        end select


    end subroutine init
    !*****************************************************************************************








    !>  Set ChiDG environment components
    !!
    !!      -   Set time-integrator
    !!      -   Set nonlinear solver
    !!      -   Set linear solver
    !!      -   Set preconditioner
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]    selector    Character string for selecting the chidg component for 
    !!                            initialization
    !!  @param[in]    selection   Character string for specializing the component being 
    !!                            initialized
    !!  @param[inout] options     Dictionary for initialization options
    !!
    !-----------------------------------------------------------------------------------------
    subroutine set(self,selector,algorithm,integer_input,real_input,options,cfl0,tol,nsteps,nwrite,norders_reduction,search)
        class(chidg_t),             intent(inout)   :: self
        character(*),               intent(in)      :: selector
        character(*),   optional,   intent(in)      :: algorithm
        integer(ik),    optional,   intent(in)      :: integer_input
        real(rk),       optional,   intent(in)      :: real_input
        type(dict_t),   optional,   intent(inout)   :: options 
        real(rk),       optional,   intent(in)      :: cfl0
        real(rk),       optional,   intent(in)      :: tol
        integer(ik),    optional,   intent(in)      :: nsteps
        integer(ik),    optional,   intent(in)      :: nwrite
        integer(rk),    optional,   intent(in)      :: norders_reduction
        logical,        optional,   intent(in)      :: search

        character(:),   allocatable :: user_msg
        integer(ik)                 :: ierr


        !
        ! Check options for the algorithm family of inputs
        !
        select case (trim(selector))
            
            case ('Time Integrator', 'Nonlinear Solver', 'Linear Solver', 'Preconditioner')

                user_msg = "chidg%set: The component being set needs an algorithm string passed in &
                            along with it. Try 'call chidg%set('your component', algorithm='your algorithm string')"
                if (.not. present(algorithm)) call chidg_signal_one(FATAL,user_msg,trim(selector))

        end select


        !
        ! Check options for integer family of inputs
        !
        select case (trim(selector))

            case ('Solution Order')

                user_msg = "chidg%set: The component being set needs an integer passed in &
                            along with it. Try 'call chidg%set('your component', integer_input=my_int)"
                if (.not. present(integer_input)) call chidg_signal_one(FATAL,user_msg,trim(selector))

        end select






        !
        ! Actually go in and call the specialized routine based on 'selector'
        !
        select case (trim(selector))
            !
            ! Allocation for time integrator
            !
            case ('Time Integrator')
                if (allocated(self%time_integrator)) deallocate(self%time_integrator)
                call create_time_integrator(algorithm,self%time_integrator)



            !
            ! Allocation for nonlinear solver
            !
            case ('Nonlinear Solver')
                if (allocated(self%nonlinear_solver)) deallocate(self%nonlinear_solver)
                call create_nonlinear_solver(algorithm,self%nonlinear_solver,options)

                if (present(cfl0))   self%nonlinear_solver%cfl0   = cfl0
                if (present(tol))    self%nonlinear_solver%tol    = tol
                if (present(nsteps)) self%nonlinear_solver%nsteps = nsteps
                if (present(nwrite)) self%nonlinear_solver%nwrite = nwrite
                if (present(search)) self%nonlinear_solver%search = search
                if (present(norders_reduction)) self%nonlinear_solver%norders_reduction = norders_reduction


            !
            ! Allocation for linear solver
            !
            case ('Linear Solver')
                if (allocated(self%linear_solver)) deallocate(self%linear_solver)
                call create_linear_solver(algorithm,self%linear_solver,options)

                if (present(tol)) self%linear_solver%tol = tol

            !
            ! Allocation for preconditioner
            !
            case ('Preconditioner')
                if (allocated(self%preconditioner)) deallocate(self%preconditioner)
                call create_preconditioner(algorithm,self%preconditioner)



            !
            ! Set the 'solution order'. Order-of-accuracy, that is. Compute the number of terms
            ! in the 1D, 3D solution bases
            !
            case ('Solution Order')
                self%nterms_s_1d = integer_input
                self%nterms_s    = self%nterms_s_1d * self%nterms_s_1d * self%nterms_s_1d
        
                

            case default
                user_msg = "chidg%set: component string was not recognized. Check spelling and that the component &
                            was registered as an option in the chidg%set routine"
                call chidg_signal_one(FATAL,user_msg,selector)


        end select


    end subroutine set
    !******************************************************************************************








    !>  Read grid from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  gridfile        String containing a grid file name, including extension.
    !!
    !!  @param[in]  equation_set    Optionally, override the equation set for all domains
    !!  
    !!  @param[in]  bc_wall         Optionally, override wall boundary functions
    !!  @param[in]  bc_inlet        Optionally, override inlet boundary functions
    !!  @param[in]  bc_outlet       Optionally, override outlet boundary functions
    !!  @param[in]  bc_symmetry     Optionally, override symmetry boundary functions
    !!  @param[in]  bc_farfield     Optionally, override farfield boundary functions
    !!  @param[in]  bc_periodic     Optionally, override periodic boundary functions
    !!
    !!  An example where overriding boundary condition is useful is computing wall distance
    !!  for a RANS calculation. First a PDE is solved using a poisson-like equation for 
    !!  wall distance and the boundary functions on walls get overridden from RANS
    !!  boundary functions to be scalar dirichlet boundary conditions. All other 
    !!  boundar functions are overridden with neumann boundary conditions.
    !!
    !------------------------------------------------------------------------------------------
    subroutine read_mesh(self,grid_file,equation_set, bc_wall, bc_inlet, bc_outlet, bc_symmetry, bc_farfield, bc_periodic, partitions_in, interpolation, level)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file
        character(*),       intent(in),     optional    :: equation_set
        class(bc_state_t),  intent(in),     optional    :: bc_wall
        class(bc_state_t),  intent(in),     optional    :: bc_inlet
        class(bc_state_t),  intent(in),     optional    :: bc_outlet
        class(bc_state_t),  intent(in),     optional    :: bc_symmetry
        class(bc_state_t),  intent(in),     optional    :: bc_farfield
        class(bc_state_t),  intent(in),     optional    :: bc_periodic
        type(partition_t),  intent(in),     optional    :: partitions_in(:)
        character(*),       intent(in),     optional    :: interpolation
        integer(ik),        intent(in),     optional    :: level


        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Reading mesh... ', io_proc=GLOBAL_MASTER)


        !
        ! Read domain geometry. Also performs partitioning.
        !
        call self%read_mesh_grids(grid_file,equation_set,partitions_in)






        !
        ! Read boundary conditions.
        !
        call self%read_mesh_boundary_conditions(grid_file, bc_wall,        &
                                                           bc_inlet,       &
                                                           bc_outlet,      &
                                                           bc_symmetry,    &
                                                           bc_farfield,    &
                                                           bc_periodic )


                                                      
        call self%read_prescribedmeshmotions(grid_file)

        !
        ! Initialize data
        !
        call self%init('all',interpolation,level)



        call write_line('Done reading mesh.', io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,   io_proc=GLOBAL_MASTER)


    end subroutine read_mesh
    !*****************************************************************************************








    !>  Read volume grid portion of mesh from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  gridfile        String containing a grid file name, including extension.
    !!  @param[in]  spacedim        Number of spatial dimensions
    !!  @param[in]  equation_set    Optionally, specify the equation set to be initialized 
    !!                              instead of
    !!
    !!  TODO: Generalize spacedim
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_mesh_grids(self,grid_file,equation_set, partitions_in)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file
        character(*),       intent(in),     optional    :: equation_set
        type(partition_t),  intent(in),     optional    :: partitions_in(:)


        type(domain_connectivity_t),    allocatable                 :: connectivities(:)
        real(rk),                       allocatable                 :: weights(:)
        type(partition_t),              allocatable, asynchronous   :: partitions(:)

        character(:),       allocatable     :: domain_equation_set
        type(meshdata_t),   allocatable     :: meshdata(:)
        integer(ik)                         :: idom, iread, ierr, ielem, eqn_ID


        call write_line(' ',                           ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   Reading domain grids... ', ltrim=.false., io_proc=GLOBAL_MASTER)



        !
        ! Partitions defined from user input
        !
        if ( present(partitions_in) ) then

            self%partition = partitions_in(IRANK+1)


        !
        ! Partitions from partitioner tool
        !
        else

            !
            ! Master rank: Read connectivity, partition connectivity, distribute partitions
            !
            call write_line("   partitioning...", ltrim=.false., io_proc=GLOBAL_MASTER)
            if ( IRANK == GLOBAL_MASTER ) then

                call read_global_connectivity_hdf(grid_file,connectivities)
                call read_weights_hdf(grid_file,weights)

                call partition_connectivity(connectivities, weights, partitions)

                call send_partitions(partitions,ChiDG_COMM)
            end if


            !
            ! All ranks: Receive partition from GLOBAL_MASTER
            !
            call write_line("   distributing partitions...", ltrim=.false., io_proc=GLOBAL_MASTER)
            call recv_partition(self%partition,ChiDG_COMM)


        end if ! partitions in from user



        !
        ! Read data from hdf file
        !
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then

                call read_equations_hdf(self%data, grid_file)
                call read_grids_hdf(grid_file,self%partition,meshdata)

            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do



        !
        ! Add domains to ChiDG%data
        !
        call write_line("   processing...", ltrim=.false., io_proc=GLOBAL_MASTER)
        do idom = 1,size(meshdata)


            ! Use equation_set if specified, else default to the grid file data
            if (present(equation_set)) then
                domain_equation_set = equation_set
                call self%data%add_equation_set(equation_set)
            else
                domain_equation_set = meshdata(idom)%eqnset
            end if



            ! Get the equation set identifier
            eqn_ID = self%data%get_equation_set_id(domain_equation_set)

            call self%data%mesh%add_domain( trim(meshdata(idom)%name),   &
                                            meshdata(idom)%nodes,        &
                                            meshdata(idom)%dnodes,       &
                                            meshdata(idom)%vnodes,       &
                                            meshdata(idom)%connectivity, &
                                            meshdata(idom)%nelements_g,  &
                                            meshdata(idom)%coord_system, &
                                            eqn_ID )



        end do !idom



        call write_line('   Done reading domains grids... ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' ',                                 ltrim=.false., io_proc=GLOBAL_MASTER)

    end subroutine read_mesh_grids
    !*****************************************************************************************











    !>  Read boundary conditions portion of mesh from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/5/2016
    !!
    !!  @param[in]  grid_file    String specifying a gridfile, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_mesh_boundary_conditions(self, grid_file, bc_wall, bc_inlet, bc_outlet, bc_symmetry, bc_farfield, bc_periodic)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file
        class(bc_state_t),  intent(in),     optional    :: bc_wall
        class(bc_state_t),  intent(in),     optional    :: bc_inlet
        class(bc_state_t),  intent(in),     optional    :: bc_outlet
        class(bc_state_t),  intent(in),     optional    :: bc_symmetry
        class(bc_state_t),  intent(in),     optional    :: bc_farfield
        class(bc_state_t),  intent(in),     optional    :: bc_periodic

        type(domain_patch_data_t),  allocatable :: domain_patch_data(:)
        type(string_t)                          :: group_name, patch_name
        type(bc_state_group_t), allocatable     :: bc_state_groups(:)
        integer(ik)                             :: idom, ndomains, ipatch, ibc, ierr, iread, bc_ID


        call write_line(' ',                                  ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   Reading boundary conditions... ', ltrim=.false., io_proc=GLOBAL_MASTER)


        !
        ! Call boundary condition reader based on file extension
        !
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then

                call read_boundaryconditions_hdf(grid_file,domain_patch_data,bc_state_groups,self%partition)

            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do





        !
        ! Add all boundary condition state groups
        !
        call write_line('   processing groups...', ltrim=.false., io_proc=GLOBAL_MASTER)
        do ibc = 1,size(bc_state_groups)

            call self%data%add_bc_state_group(bc_state_groups(ibc), bc_wall     = bc_wall,      &
                                                                    bc_inlet    = bc_inlet,     &
                                                                    bc_outlet   = bc_outlet,    &
                                                                    bc_symmetry = bc_symmetry,  &
                                                                    bc_farfield = bc_farfield,  &
                                                                    bc_periodic = bc_periodic )
      
        end do !ibc



        !
        ! Add boundary condition patch groups
        !
        call write_line('   processing patches...', ltrim=.false., io_proc=GLOBAL_MASTER)
        ndomains = size(domain_patch_data)
        do idom = 1,ndomains
            do ipatch = 1,domain_patch_data(idom)%patch_name%size()

                group_name = domain_patch_data(idom)%group_name%at(ipatch)
                patch_name = domain_patch_data(idom)%patch_name%at(ipatch)

                bc_ID = self%data%get_bc_state_group_id(group_name%get())

                call self%data%mesh%add_bc_patch(domain_patch_data(idom)%domain_name,               &
                                                 group_name%get(),                                  &
                                                 patch_name%get(),                                  &
                                                 domain_patch_data(idom)%bc_connectivity(ipatch),   &
                                                 bc_ID)

            end do !iface
        end do !ipatch



        call write_line('   Done reading boundary conditions.', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' ',                                    ltrim=.false., io_proc=GLOBAL_MASTER)


    end subroutine read_mesh_boundary_conditions
    !*****************************************************************************************





    !>  Read prescribed mesh motions from grid file.
    !!
    !!  @author Eric Wolf
    !!  @date  3/30/2017 
    !!
    !!  @param[in]  grid_file    String specifying a grid_file, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_prescribedmeshmotions(self, grid_file)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file

        character(5),           dimension(1)    :: extensions
        character(:),           allocatable     :: extension
        type(prescribed_mesh_motion_domain_data_t),  allocatable     :: pmm_domain_data(:)
        type(string_t)                          :: pmm_group_name
        type(prescribed_mesh_motion_group_wrapper_t)            :: pmm_group_wrapper
        type(string_t)                          :: group_name
        integer(ik)                                 :: idom, ndomains, iface, ibc, ierr, iread, npmm_groups


        !
        ! Get filename extension
        !
        extensions = ['.h5']
        extension = get_file_extension(grid_file, extensions)


        !
        ! Call boundary condition reader based on file extension
        !
        call write_line('Prescribed Mesh Motions: reading...', io_proc=GLOBAL_MASTER)
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then


                if ( extension == '.h5' ) then
                    call read_prescribedmeshmotion_hdf(grid_file,pmm_domain_data,pmm_group_wrapper,self%partition)
                else
                    call chidg_signal(FATAL,"chidg%read_boundaryconditions: grid file extension not recognized")
                end if


            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do





        call write_line('Prescribed Mesh Motions: processing...', io_proc=GLOBAL_MASTER)
        !
        ! Add all boundary condition groups
        !
        npmm_groups = pmm_group_wrapper%ngroups
        if (npmm_groups>0) then
        do ibc = 1,npmm_groups

            call self%data%add_pmm_group(pmm_group_wrapper%pmm_groups(ibc))

        end do !ibc
        end if


        !
        ! Add boundary condition patches
        !
        if (npmm_groups>0) then
        ndomains = size(pmm_domain_data)
        do idom = 1,ndomains
            
            call pmm_group_name%set(pmm_domain_data(idom)%pmm_group_name)
            call self%data%add_pmm_domain(pmm_domain_data(idom)%domain_name,            &
                                        pmm_group_name%get())

        end do !ipatch
        end if




    end subroutine read_prescribedmeshmotions
    !*****************************************************************************************









    !>  Read fields from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_fields(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name


        call write_line(' ',                            ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' Reading solution... ',        ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   reading from: ', file_name, ltrim=.false., io_proc=GLOBAL_MASTER)


        !
        ! Read solution from hdf file
        !
        call read_fields_hdf(file_name,self%data)


        call write_line('Done reading solution.', io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,       io_proc=GLOBAL_MASTER)

    end subroutine read_fields
    !*****************************************************************************************










!    !>  Check the equation_set's for any auxiliary fields that are required. 
!    !!
!    !!      #1: Check equation_set's for auxiliary fields
!    !!      #2: For auxiliary fields that are found, check the file for the auxiliary field.
!    !!      #3: If no auxiliary field in file, check auxiliary drivers for a rule to compute the field
!    !!      #4: If no rule, error. We don't have the field, and we also don't know how to compute it.
!    !!
!    !!  @author Nathan A. Wukie
!    !!  @date   11/21/2016
!    !!
!    !!
!    !!
!    !-----------------------------------------------------------------------------------------
!    subroutine check_auxiliary_fields(self)
!        class(chidg_t), intent(inout)   :: self
!
!        type(string_t), allocatable :: auxiliary_fields(:)
!        logical,        allocatable :: domain_needs_aux_field(:)
!        logical,        allocatable :: file_has_aux_field(:)
!        logical,        allocatable :: field_in_file
!
!
!
!!        aux_fields = self%data%get_auxiliary_fields()
!!
!!
!!        do iaux = 1,size(aux_fields)
!!
!!
!!            !
!!            ! Check which domains use the auxiliary field
!!            !
!!            do idom = 1,self%data%ndomains()
!!                  ! NOTE: If anyone uncomments this, eqnset(idom) should probably be replaced with eqn_ID
!!                domain_uses_field(idom) = self%data%eqnset(idom)%uses_auxiliary_field(aux_fields(iaux))
!!            end do !idom
!!
!!
!!            !
!!            do idom = 1,self%data%ndomains()
!!                file_has_aux_field(idom) = file%domain_has_field(idom,aux_field(iaux))
!!            end do !idom
!!
!!
!!            !
!!            ! If any domain doesn't have the field in file, get from a pre-defined rule
!!            !
!!            if (any(file_has_aux_field == .false.)) then
!!                call initialize_auxiliary_field(aux_field(iaux))
!!            end if
!!
!!
!!        end do !iaux
!
!        
!
!
!    end subroutine check_auxiliary_fields
!    !*****************************************************************************************







    !>  Write grid to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/21/2016
    !!
    !!  @param[in]  file    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_mesh(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name

        integer(ik)     :: ierr, iproc, iwrite
        integer(HID_T)  :: fid
        logical         :: file_exists

        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Writing mesh... ', io_proc=GLOBAL_MASTER)



        !
        ! Check for file existence
        !
        ! Create new file if necessary
        !   Barrier makes sure everyone has called file_exists before
        !   one potentially gets created by another processor
        !
        file_exists = check_file_exists_hdf(file_name)
        call MPI_Barrier(ChiDG_COMM,ierr)
        if (.not. file_exists) then

                ! Create a new file
                if (IRANK == GLOBAL_MASTER) then
                    call initialize_file_hdf(file_name)
                end if
                call MPI_Barrier(ChiDG_COMM,ierr)

                ! Initialize the file structure.
                do iproc = 0,NRANK-1
                    if (iproc == IRANK) then
                        fid = open_file_hdf(file_name)
                        call initialize_file_structure_hdf(fid,self%data)
                        call close_file_hdf(fid)
                    end if
                    call MPI_Barrier(ChiDG_COMM,ierr)
                end do

        end if
        call MPI_Barrier(ChiDG_COMM,ierr)








        !
        ! Call grid reader based on file extension
        !
        call write_line("   writing to: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        !
        ! Each process, write its own portion of the solution
        !
        do iwrite = 0,NRANK-1
            if ( iwrite == IRANK ) then

                call write_grids_hdf(self%data,file_name)
                call write_boundaryconditions_hdf(self%data,file_name)
                call write_equations_hdf(self%data,file_name)

            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do



        call write_line("Done writing mesh.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,   io_proc=GLOBAL_MASTER)

    end subroutine write_mesh
    !*****************************************************************************************









    !>  Write solution to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_fields(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name


        call write_line(' ', ltrim=.false.,     io_proc=GLOBAL_MASTER)
        call write_line('Writing solution... ', io_proc=GLOBAL_MASTER)
        call write_line("   writing to:", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)


        !
        ! Call grid reader based on file extension
        !
        call write_fields_hdf(self%data,file_name)
        call self%time_integrator%write_time_options(self%data,file_name)



        call write_line("Done writing solution.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,       io_proc=GLOBAL_MASTER)

    end subroutine write_fields
    !*****************************************************************************************





    !>  Write visualization to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   8/24/2017
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine produce_visualization(self,grid_file,solution_file,equation_set)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: grid_file
        character(*),       intent(in)              :: solution_file
        character(*),       intent(in), optional    :: equation_set

        character(:),   allocatable :: user_msg, time_integrator, solution_file_prefix
        integer(ik),    allocatable :: solution_orders(:)
        integer(HID_T)              :: fid
        

        call write_line(' ', ltrim=.false.,          io_proc=GLOBAL_MASTER)
        call write_line('Writing visualization... ', io_proc=GLOBAL_MASTER)


        !
        ! Check we are running serial
        !
        user_msg = "chidg%produce_visualization: We currently can only write &
                    visualization files in serial. Please run using a single process."
        if (NRANK > 1) call chidg_signal(FATAL,user_msg)



        !
        ! Get properties from solution_file and set
        !
        fid = open_file_hdf(solution_file)
        solution_orders = get_domain_field_orders_hdf(fid)
        time_integrator = get_time_integrator_hdf(fid)
        call close_file_hdf(fid)


        !
        ! Initialize solution data storage
        !
        call self%set('Solution Order', integer_input=solution_orders(1))
        call self%set('Time Integrator', algorithm=trim(time_integrator))
        self%solution_file_in = solution_file


        !
        ! Read grid/solution modes and time integrator options from HDF5
        !
        self%grid_file = grid_file
        call self%read_mesh(grid_file, interpolation='Uniform', level=OUTPUT_RES, equation_set=equation_set)
        call self%read_fields(solution_file)


        !
        ! Process for getting wall distance
        !
        call self%process()


        call self%time_integrator%initialize_state(self%data)
        call self%time_integrator%read_time_options(self%data,solution_file,'process')
        call self%time_integrator%process_data_for_output(self%data)


        !
        ! Write solution
        !
        solution_file_prefix = get_file_prefix(solution_file,'.h5')
        call write_tecio(self%data,solution_file_prefix, write_domains=.true., write_surfaces=.true.)


        call write_line("Done writing visualization.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,            io_proc=GLOBAL_MASTER)

    end subroutine produce_visualization
    !*****************************************************************************************












    !>  Handle prerun activities, such as initializing auxiliary fields and
    !!  calling auxiliary drivers.
    !!
    !!  Checks:
    !!  ----------------------------
    !!      1: Check if 'Wall Distance : p-Poisson' is required. Yes => call auxiliary_driver
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   6/24/2017
    !!
    !!
    !-------------------------------------------------------------------------------------------
    subroutine process(self)
        class(chidg_t), intent(inout)   :: self


        character(:),   allocatable :: user_msg
        integer(ik)                 :: ifield, ierr, iproc
        type(svector_t)             :: auxiliary_fields_local
        type(string_t)              :: field_name
        logical                     :: has_wall_distance, all_have_wall_distance


        auxiliary_fields_local = self%data%get_auxiliary_field_names()


        !
        ! Rule for 'Wall Distance'
        !   1: Detect if proc requires auxiliary field 'Wall Distance : p-Poisson' be provided.
        !   2: Detect if all procs require 'Wall Distance : p-Poisson'. MPI_AllReduce
        !   3: If all procs require auxiliary field, call auxiliary_driver for 'Wall Distance'
        !
        !-------------------------------------------------------------------------------------
        has_wall_distance = .false.
        do ifield = 1,auxiliary_fields_local%size()
            field_name = auxiliary_fields_local%at(ifield)
            has_wall_distance = (field_name%get() == 'Wall Distance : p-Poisson')
            if (has_wall_distance) exit
        end do !ifield

        call MPI_AllReduce(has_wall_distance, all_have_wall_distance, 1, MPI_LOGICAL, MPI_LOR, ChiDG_COMM, ierr)

        if (all_have_wall_distance) then
            allocate(self%auxiliary_environment, stat=ierr)
            if (ierr /= 0) call AllocationError
            call auxiliary_driver(self,self%auxiliary_environment,'Wall Distance', grid_file = trim(self%grid_file),    &
                                                                                   aux_file  = 'wall_distance.h5')
        end if
        !*************************************************************************************




    end subroutine process
    !*******************************************************************************************






    !>  Run ChiDG simulation
    !!
    !!      - This routine passes the domain data, nonlinear solver, linear solver, and 
    !!        preconditioner components to the time integrator to take a step.
    !!
    !!  Optional input parameters:
    !!      write_initial   control writing initial solution to file. Default: .false.
    !!      write_final     control writing final solution to file. Default: .true.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!  @date   2/7/2017
    !!
    !------------------------------------------------------------------------------------------
    subroutine run(self, write_initial, write_final)
        class(chidg_t), intent(inout)           :: self
        logical,        intent(in), optional    :: write_initial
        logical,        intent(in), optional    :: write_final

        character(100)              :: filename
        character(:),   allocatable :: prefix
        integer(ik)                 :: istep, nsteps, wcount, iread, ierr
        logical                     :: option_write_initial, option_write_final

        class(chidg_t), pointer :: chidg
    

        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("           Running ChiDG simulation...             ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)


        !
        ! Prerun processing
        !   : Getting/computing auxiliary fields etc.
        !
        call self%process()



        !
        ! Initialize algorithms
        !
        call self%init('algorithms')


        !
        ! Check optional incoming parameters
        !
        option_write_initial = .false.
        option_write_final   = .true.
        if (present(write_initial)) option_write_initial = write_initial
        if (present(write_final))   option_write_final   = write_final




        !
        ! Write initial solution
        !
        if (option_write_initial) then
            call self%write_mesh('initial.h5')
            call self%write_fields('initial.h5')
        end if




        
        !
        ! Initialize time integrator state
        !
        call self%time_integrator%initialize_state(self%data)

        do iread = 0,NRANK-1
            if ( iread == IRANK ) then
                if (solutionfile_in /= 'none') call self%time_integrator%read_time_options(self%data,solutionfile_in,'run')
            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do



        
        !
        ! Get the prefix in the file name in case of multiple output files
        !
        prefix = get_file_prefix(solutionfile_out,'.h5')       




        !
        ! Execute time_integrator, nsteps times 
        !
        wcount = 1
        nsteps = self%data%time_manager%nsteps
        call write_line("Step","System residual", columns=.true., column_width=30, io_proc=GLOBAL_MASTER)
        do istep = 1,nsteps
            

            !
            ! Call time integrator to take a step. 
            !
            call self%time_integrator%step(self%data,               &
                                           self%nonlinear_solver,   &
                                           self%linear_solver,      &
                                           self%preconditioner)
           
           

            !
            ! Write solution every nwrite steps
            !
            if (wcount == self%data%time_manager%nwrite) then
                if (self%data%time_manager%t < 1.) then
                    write(filename, "(A,F8.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                else
                    write(filename, "(A,F0.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                end if
                call self%write_mesh(filename)
                call self%write_fields(filename)
                wcount = 0
            end if



            !
            ! Print diagnostics
            !
            call write_line("TIME INTEGRATOR", istep, self%time_integrator%residual_norm%at(istep), io_proc=GLOBAL_MASTER)


            wcount = wcount + 1


        end do !istep

                
        !
        ! Write the final solution to hdf file
        !        
        if (option_write_final) then
            call self%write_mesh(solutionfile_out)
            call self%write_fields(solutionfile_out)
        end if


    end subroutine run
    !*****************************************************************************************










    !> Report on ChiDG simulation
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine report(self,selection)
        class(chidg_t), intent(inout)   :: self
        character(*),   intent(in)      :: selection

        integer(ik) :: ireport, ierr


        if ( trim(selection) == 'before' ) then


            do ireport = 0,NRANK-1
                if ( ireport == IRANK ) then
                    call write_line('MPI Rank: ', IRANK, io_proc=IRANK)
                    call self%data%report('grid')
                end if
                call MPI_Barrier(ChiDG_COMM,ierr)
            end do




        else if ( trim(selection) == 'after' ) then

            if ( IRANK == GLOBAL_MASTER ) then
                !call self%time_integrator%report()
                call self%nonlinear_solver%report()
                !call self%preconditioner%report()
            end if

        end if


    end subroutine report
    !*****************************************************************************************











    function compute_l2_state_error(self,q_ref) result(error_val)
        class(chidg_t), intent(inout)       :: self
        type(chidg_vector_t), intent(in)    :: q_ref

        type(chidg_vector_t), allocatable    :: q_diff
        real(rk)                            :: error_val, local_error_val

        integer(ik)                         :: ndom, nelems, neqns, nterms, idom, ielem, iterm, ieqn
        real(rk), allocatable               :: temp(:)
        q_diff = q_ref
        q_diff = sub_chidg_vector_chidg_vector(self%data%sdata%q,q_ref)
        error_val = ZERO
        !error_val = q_diff%norm_local()

        ndom = self%data%mesh%ndomains()
        do idom = 1, ndom
            nelems = self%data%mesh%domain(idom)%nelem
            neqns = self%data%mesh%domain(idom)%neqns
            nterms = self%data%mesh%domain(idom)%nterms_s
            do ielem = 1, nelems
                local_error_val = ZERO
                do ieqn = 1, neqns
                    temp = &
                        matmul(self%data%mesh%domain(idom)%elems(ielem)%basis_s%interpolator('Value'),&
                    q_diff%dom(idom)%vecs(ielem)%vec((ieqn-1)*nterms+1:ieqn*nterms))
                    temp = temp**TWO*self%data%mesh%domain(idom)%elems(ielem)%basis_s%weights()*self%data%mesh%domain(idom)%elems(ielem)%jinv
                    local_error_val = local_error_val + sum(temp)
                end do
                error_val = error_val + local_error_val
            end do
        end do
        error_val = sqrt(error_val)
    end function compute_l2_state_error







end module type_chidg
