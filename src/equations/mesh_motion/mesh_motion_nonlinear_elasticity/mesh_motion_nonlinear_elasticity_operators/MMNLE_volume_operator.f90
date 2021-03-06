module MMNLE_volume_operator
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO,ONE,TWO,HALF

    use type_operator,          only: operator_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use DNAD_D
    use ieee_arithmetic
    implicit none
    private

    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !-------------------------------------------------------------------------
    type, extends(operator_t), public :: MMNLE_volume_operator_t


    contains

        procedure   :: init
        procedure   :: compute

    end type MMNLE_volume_operator_t
    !*************************************************************************

contains


    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(MMNLE_volume_operator_t),   intent(inout)      :: self

        ! Set operator name
        call self%set_name('Mesh Motion Nonlinear Elasticity Volume Operator')

        ! Set operator type
        call self%set_operator_type('Volume Diffusive Operator')

        ! Set operator equations
        call self%add_primary_field('grid_displacement1')
        call self%add_primary_field('grid_displacement2')
        call self%add_primary_field('grid_displacement3')

    end subroutine init
    !********************************************************************************





    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------
    subroutine compute(self,worker,prop)
        class(MMNLE_volume_operator_t),    intent(inout)   :: self
        type(chidg_worker_t),           intent(inout)   :: worker
        class(properties_t),            intent(inout)   :: prop


        type(AD_D), allocatable, dimension(:)   ::  &
            flux_1, flux_2, flux_3,  mu, &
            grad1_u1, grad2_u1, grad3_u1, &
            grad1_u2, grad2_u2, grad3_u2, &
            grad1_u3, grad2_u3, grad3_u3
        

        !
        ! Interpolate solution to quadrature nodes
        !
        grad1_u1 = worker%get_primary_field_element('grid_displacement1','grad1 + lift')
        grad2_u1 = worker%get_primary_field_element('grid_displacement1','grad2 + lift')
        grad3_u1 = worker%get_primary_field_element('grid_displacement1','grad3 + lift')

        grad1_u2 = worker%get_primary_field_element('grid_displacement2','grad1 + lift')
        grad2_u2 = worker%get_primary_field_element('grid_displacement2','grad2 + lift')
        grad3_u2 = worker%get_primary_field_element('grid_displacement2','grad3 + lift')

        grad1_u3 = worker%get_primary_field_element('grid_displacement3','grad1 + lift')
        grad2_u3 = worker%get_primary_field_element('grid_displacement3','grad2 + lift')
        grad3_u3 = worker%get_primary_field_element('grid_displacement3','grad3 + lift')


        !
        ! Compute scalar coefficient
        ! 
        mu = worker%get_model_field_element('Mesh Motion Nonlinear Elasticity Coefficient', 'value')


        !
        ! Compute volume flux at quadrature nodes
        !

        !GD1
        flux_1 = -mu*grad1_u1
        flux_2 = -mu*grad2_u1
        flux_3 = -mu*grad3_u1


        !
        ! Integrate volume flux
        !
        call worker%integrate_volume('grid_displacement1',flux_1,flux_2,flux_3)

        !GD2
        flux_1 = -mu*grad1_u2
        flux_2 = -mu*grad2_u2
        flux_3 = -mu*grad3_u2


        !
        ! Integrate volume flux
        !
        call worker%integrate_volume('grid_displacement2',flux_1,flux_2,flux_3)

        !GD3
        flux_1 = -mu*grad1_u3
        flux_2 = -mu*grad2_u3
        flux_3 = -mu*grad3_u3


        !
        ! Integrate volume flux
        !
        call worker%integrate_volume('grid_displacement3',flux_1,flux_2,flux_3)





    end subroutine compute
    !****************************************************************************************************






end module MMNLE_volume_operator
