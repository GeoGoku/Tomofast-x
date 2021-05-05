
!========================================================================
!
!                    T O M O F A S T X  Version 1.0
!                  ----------------------------------
!
!              Main authors: Vitaliy Ogarko, Roland Martin,
!                   Jeremie Giraud, Dimitri Komatitsch.
! CNRS, France, and University of Western Australia.
! (c) CNRS, France, and University of Western Australia. January 2018
!
! This software is a computer program whose purpose is to perform
! capacitance, gravity, magnetic, or joint gravity and magnetic tomography.
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================

module init_parameters

  use global_typedefs
  use mpi_tools, only: exit_MPI
  use sanity_check
  use parameters_ect
  use parameters_grav
  use parameters_mag
  use parameters_inversion
  use geometry, only: get_refined_ntheta
  use parallel_tools

  implicit none

  private

  public :: initialize_parameters
  public :: get_problem_type

  private :: read_parfile

contains

!==========================================================================
! Get problem type (ECT / Gravity).
!==========================================================================
subroutine get_problem_type(problem_type, myrank)
  integer, intent(in) :: myrank
  integer, intent(out) :: problem_type
  character(len=256) :: arg

  ! ECT problem is set by default.
  arg = '-e'
  problem_type = 1

  if (command_argument_count() > 0) call get_command_argument(1, arg)

  if (arg == '-e') then
    problem_type = 1
    if (myrank == 0) print *, '===== START ECT PROBLEM ====='
  else if (arg == '-g') then
    problem_type = 2
    if (myrank == 0) print *, '===== START GRAVITY PROBLEM ====='
  else if (arg == '-m') then
    problem_type = 3
    if (myrank == 0) print *, '===== START MAGNETISM PROBLEM ====='
  else if (arg == '-j') then
    problem_type = 4
    if (myrank == 0) print *, '===== START JOINT GRAV/MAG PROBLEM ====='
  else
    call exit_MPI("UNKNOWN PROBLEM TYPE! arg ="//arg, myrank, 0)
  endif

end subroutine get_problem_type

!=======================================================================================
! TODO: Split to ect, grav & mag routines.
! Initialize parameters for forward and inverse problems.
!=======================================================================================
subroutine initialize_parameters(problem_type, epar, gpar, mpar, ipar, myrank, nbproc)
  integer, intent(in) :: problem_type
  integer, intent(in) :: myrank,nbproc

  type(t_parameters_ect), intent(out) :: epar
  type(t_parameters_grav), intent(out) :: gpar
  type(t_parameters_mag), intent(out) :: mpar
  type(t_parameters_inversion), intent(out) :: ipar

  type(t_parameters_base) :: gmpar
  type(t_parallel_tools) :: pt
  integer :: nelements, ierr

  if (myrank == 0) then
    ! Read Parfile data, only the master does this,
    ! and then broadcasts all the information to the other processes.
    call read_parfile(epar, gpar, mpar, ipar, myrank)

    ! Global sanity checks.
    if (problem_type == 1) then
      ! ntheta is a multiple of the number of electrodes.
      call sanity_ntheta_nel(epar%dims%ntheta, epar%nel / epar%nrings, myrank)
      ! nz is a multiple of the number of processes.
      call sanity_nz(epar%dims%nz, nbproc, myrank)
    endif
  endif

  ! Use barrier to do not mix the parameters output from the master CPU with other log messages.
  call MPI_BARRIER(MPI_COMM_WORLD,ierr)

  ! All sanity checks passed so far, so we may broadcast the Parfile.

  ! MPI broadcast parameters.
  call MPI_Bcast(path_output, len(path_output), MPI_CHAR, 0, MPI_COMM_WORLD, ierr)

  if (problem_type == 1) then
    call epar%broadcast()

  else if (problem_type == 2) then
    call gpar%broadcast(myrank)

  else if (problem_type == 3) then
    call mpar%broadcast(myrank)

  else if (problem_type == 4) then
    call gpar%broadcast(myrank)
    call mpar%broadcast(myrank)
  endif

  call ipar%broadcast(myrank)

  !--------------------------------
  ! Some extra initializations.
  !--------------------------------
  if (problem_type == 1) then
  ! Electrical capacitance tomography (ECT) problem.

    epar%read_guess_from_file = .false.

    !-----------------------
    ! PARTITIONING FOR MPI

    ! Cut the model into vertical slices for MPI,
    ! always divides evenly because of the previous sanity check.
    epar%dims%nzlocal = epar%dims%nz / nbproc

    ! Initialize dimensions of the sensitivity matrix in inverse problem (nelements x ndata+nelements).
    ipar%nelements_total = epar%dims%nr * epar%dims%ntheta * (epar%dims%nz + 1)

    ipar%nx = epar%dims%nr
    ipar%ny = epar%dims%ntheta

    ! We have nzlocal+1 k-elements in the last processor,
    ! since the model is defined in the middle of the potential (phi) grid nodes, which run from 0 to nz+1.
    ! So for nz=4, phi-nodes are:   0   1   2   3   4   5, and
    !              model-nodes are:   1   2   3   4   5, i.e., not even number.
    ipar%nz = epar%dims%nzlocal + (myrank + 1) / nbproc

    ipar%nelements = ipar%nx * ipar%ny * ipar%nz

    ipar%ndata = epar%get_ndata()

    !-----------------------------------
    ! CHANGE NTHETA FOR MESH REFINEMENT

    epar%dims%ntheta0 = epar%dims%ntheta
    ! Increase theta-dimension for mesh refinement.
    if (epar%irefine == 1) then
      ! Sanity checks.
      if (epar%linear_solver == LINSOLV_MG) then
        call exit_MPI("Mesh refinement is not implemented for the MG solver!", myrank, 0)
      endif
      if (epar%sens%space_electrodes == 0._CUSTOM_REAL) then
        call exit_MPI("Mesh refinement is implemented only for the case with gaps between electrodes!", myrank, 0)
      endif

      epar%dims%ntheta = get_refined_ntheta(epar%dims%ntheta, epar%nel)
      if (myrank == 0) print *, 'ntheta_read0, ntheta(new)', epar%dims%ntheta0, epar%dims%ntheta
    endif

  else if (problem_type == 2 .or. problem_type == 3 .or. problem_type == 4) then
  ! Gravity and magnetism problems.

    if (problem_type == 2 .or. problem_type == 4) then
    ! Gravity.

      gpar%ncomponents = 1

      gmpar = gpar%t_parameters_base
    endif

    if (problem_type == 3 .or. problem_type == 4) then
    ! Magnetism.

      mpar%ncomponents = 1

      gmpar = mpar%t_parameters_base
    endif

    ! Inverse problem parameters. -------------------------------
    ipar%nx = gmpar%nx
    ipar%ny = gmpar%ny
    ipar%nz = gmpar%nz

    ipar%ndata(1) = gpar%ndata
    ipar%ndata(2) = mpar%ndata

    ipar%nelements_total = ipar%nx * ipar%ny * ipar%nz

    ! Define model splitting for parallelization.
    nelements = pt%calculate_nelements_at_cpu(ipar%nelements_total, myrank, nbproc)

    ipar%nelements = nelements
    gpar%nelements = nelements
    mpar%nelements = nelements

  endif

  !---------------------------------------------------------------------------
  ! Print out some useful debug information.
  if (myrank == 0 .or. myrank == nbproc - 1) &
    print *, 'myrank=', myrank, ' nbproc=', nbproc, ' nelements_total=', ipar%nelements_total, &
             'nelements=', ipar%nelements, 'ndata=', ipar%ndata

end subroutine initialize_parameters

!===================================================================================
! Read input parameters from Parfile.
!===================================================================================
subroutine read_parfile(epar, gpar, mpar, ipar, myrank)
  integer, intent(in) :: myrank

  type(t_parameters_ect), intent(out) :: epar
  type(t_parameters_grav), intent(out) :: gpar
  type(t_parameters_mag), intent(out) :: mpar
  type(t_parameters_inversion), intent(out) :: ipar

  integer :: itmp, tmparr(2)

  ! This is junk in order to ignore the variable name at the beginning of the line.
  ! This ignores exactly 40 characters.
  character(len=40) :: junk
  character(len=256) :: parfile_name
  character(len=128) :: dum

  ! The name of the Parfile can be passed in via the command line,
  ! if no argument is given, the default value is used.
  call get_command_argument(2,parfile_name)
  if (len_trim(parfile_name) == 0) parfile_name = "parfiles/Parfile_MASTER.txt"

  open(unit=10,file=parfile_name,status='old',iostat=itmp,action='read')
  if (itmp /= 0) call exit_MPI("Parfile """ // trim(parfile_name) // """ cannot be opened!",myrank,15)

  ! GLOBAL -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,3) junk, path_output
  if (myrank == 0) print *,junk,trim(path_output)

  ! DIMENSIONS -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk,epar%dims%nr
  if (myrank == 0) print *,junk,epar%dims%nr

  read(10,2) junk,epar%dims%ntheta
  if (epar%dims%ntheta == 0) epar%dims%ntheta = epar%dims%nr
  if (myrank == 0) print *,junk,epar%dims%ntheta

  read(10,2) junk,epar%dims%nz
  if (epar%dims%nz == 0) epar%dims%nz = epar%dims%nr
  if (myrank == 0) print *,junk,epar%dims%nz

  ! GEOMETRY -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk,epar%nel
  if (myrank == 0) print *,junk,epar%nel

  read(10,2) junk,epar%nrings
  if (myrank == 0) print *,junk,epar%nrings

  read(10,2) junk,epar%dims%kguards
  if (epar%dims%kguards == 0) epar%dims%kguards = epar%dims%nz/4
  if (myrank == 0) print *,junk,epar%dims%kguards

  read(10,2) junk,epar%ifixed_elecgeo
  if (myrank == 0) print *,junk,epar%ifixed_elecgeo

  read(10,2) junk,epar%irefine
  if (myrank == 0) print *,junk,epar%irefine

  read(10,1) junk,epar%sens%radiusin
  if (myrank == 0) print *,junk,epar%sens%radiusin

  read(10,1) junk,epar%sens%radiusout
  if (myrank == 0) print *,junk,epar%sens%radiusout

  read(10,1) junk,epar%sens%radiusoutout
  if (myrank == 0) print *,junk,epar%sens%radiusoutout

  read(10,1) junk,epar%sens%heicyl
  if (myrank == 0) print *,junk,epar%sens%heicyl

  read(10,1) junk,epar%sens%space_elec_guards
  if (myrank == 0) print *,junk,epar%sens%space_elec_guards

  read(10,1) junk,epar%sens%space_electrodes
  if (myrank == 0) print *,junk,epar%sens%space_electrodes

  ! MODEL -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk,epar%num_bubbles
  if (myrank == 0) print *,junk,epar%num_bubbles

  read(10,3) junk, epar%filename_bubbles
  if (myrank == 0) print *, junk, trim(epar%filename_bubbles)

  read(10,1) junk,epar%permit0
  if (myrank == 0) print *,junk,epar%permit0

  read(10,1) junk,epar%permit_air
  if (myrank == 0) print *,junk,epar%permit_air

  read(10,1) junk,epar%permit_isolated_tube
  if (myrank == 0) print *,junk,epar%permit_isolated_tube

  read(10,1) junk,epar%permit_oil
  if (myrank == 0) print *,junk,epar%permit_oil

  ! SOLVER parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  epar%linear_solver = LINSOLV_PCG

  read(10,2) junk,epar%iprecond
  if (myrank == 0) print *,junk,epar%iprecond

  read(10,1) junk,epar%omega1
  if (myrank == 0) print *,junk, epar%omega1

  read(10,2) junk,epar%itypenorm
  if (epar%itypenorm == 1) then
    epar%itypenorm = NORM_L2
  else if (epar%itypenorm == 2) then
    epar%itypenorm = NORM_MAX
  else
   call exit_MPI("wrong setting for type of norm, must be 1 for L2- or 2 for max-norm; exiting...",myrank,17)
  endif
  if (myrank == 0) print *,junk,epar%itypenorm

  read(10,2) junk,epar%itmax
  if (myrank == 0) print *,junk,epar%itmax

  read(10,2) junk,epar%output_frequency
  if (myrank == 0) print *,junk,epar%output_frequency

  read(10,1) junk,epar%tol
  if (myrank == 0) print *,junk,epar%tol

  ! MULTIGRID parameters -------------------------------

  ! Removed multigrid, keep this not to change a lot of code.
  epar%ilevel_coarse = 1
  epar%coarse_solver = LINSOLV_PCG

  ! GRAVITY / MAGNETISM parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,'(a)', advance='NO') junk
  read(10,*) gpar%nx, gpar%ny, gpar%nz
  if (myrank == 0) print *, junk, gpar%nx, gpar%ny, gpar%nz

  mpar%nx = gpar%nx
  mpar%ny = gpar%ny
  mpar%nz = gpar%nz

  read(10,3) junk, gpar%model_files(1)
  if (myrank == 0) print *, junk, trim(gpar%model_files(1))

  read(10,3) junk, mpar%model_files(1)
  if (myrank == 0) print *, junk, trim(mpar%model_files(1))

  read(10,2) junk, gpar%depth_weighting_type
  if (myrank == 0) print *, junk, gpar%depth_weighting_type

  mpar%depth_weighting_type = gpar%depth_weighting_type

  ! GRAV / MAG DATA parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, gpar%ndata
  if (myrank == 0) print *, junk, gpar%ndata

  read(10,2) junk, mpar%ndata
  if (myrank == 0) print *, junk, mpar%ndata

  read(10,3) junk, gpar%data_grid_file
  if (myrank == 0) print *, junk, trim(gpar%data_grid_file)

  read(10,3) junk, mpar%data_grid_file
  if (myrank == 0) print *, junk, trim(mpar%data_grid_file)

  read(10,3) junk, gpar%data_file
  if (myrank == 0) print *, junk, trim(gpar%data_file)

  read(10,3) junk, mpar%data_file
  if (myrank == 0) print *, junk, trim(mpar%data_file)

  read(10,2) junk, gpar%calc_data_directly
  if (myrank == 0) print *, junk, gpar%calc_data_directly

  mpar%calc_data_directly = gpar%calc_data_directly

  ! PRIOR MODEL -----------------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, gpar%prior_model_type
  if (myrank == 0) print *, junk, gpar%prior_model_type
  
  mpar%prior_model_type = gpar%prior_model_type
  
  read(10,2) junk, gpar%number_prior_models
  if (myrank == 0) print *, junk, gpar%number_prior_models

  mpar%number_prior_models = gpar%number_prior_models

  read(10,1) junk, gpar%prior_model_val
  if (myrank == 0) print *, junk, gpar%prior_model_val

  read(10,1) junk, mpar%prior_model_val
  if (myrank == 0) print *, junk, mpar%prior_model_val

  read(10,3) junk, gpar%model_files(2)
  if (myrank == 0) print *, junk, trim(gpar%model_files(2))

  read(10,3) junk, mpar%model_files(2)
  if (myrank == 0) print *, junk, trim(mpar%model_files(2))

  ! STARTING MODEL ---------------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, gpar%start_model_type
  if (myrank == 0) print *, junk, gpar%start_model_type

  mpar%start_model_type = gpar%start_model_type

  read(10,1) junk, gpar%start_model_val
  if (myrank == 0) print *, junk, gpar%start_model_val

  read(10,1) junk, mpar%start_model_val
  if (myrank == 0) print *, junk, mpar%start_model_val

  read(10,3) junk, gpar%model_files(3)
  if (myrank == 0) print *, junk, trim(gpar%model_files(3))

  read(10,3) junk, mpar%model_files(3)
  if (myrank == 0) print *, junk, trim(mpar%model_files(3))

  ! MAGNETIC constants -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, mpar%mi
  if (myrank == 0) print *, junk, mpar%mi

  read(10,1) junk, mpar%md
  if (myrank == 0) print *, junk, mpar%md

  read(10,1) junk, mpar%fi
  if (myrank == 0) print *, junk, mpar%fi

  read(10,1) junk, mpar%fd
  if (myrank == 0) print *, junk, mpar%fd

  read(10,1) junk, mpar%intensity
  if (myrank == 0) print *, junk, mpar%intensity

  read(10,1) junk, mpar%theta
  if (myrank == 0) print *, junk, mpar%theta

  read(10,1) junk, mpar%beta
  if (myrank == 0) print *, junk, mpar%beta

  read(10,1) junk, mpar%Z0
  if (myrank == 0) print *, junk, mpar%Z0

  ! GRAVITY constants -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, gpar%beta
  if (myrank == 0) print *, junk, gpar%beta

  read(10,1) junk, gpar%Z0
  if (myrank == 0) print *, junk, gpar%Z0

  ! MATRIX COMPRESSION parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, gpar%distance_threshold
  if (myrank == 0) print *, junk, gpar%distance_threshold

  read(10,1) junk, gpar%compression_rate
  if (myrank == 0) print *, junk, gpar%compression_rate

  mpar%distance_threshold = gpar%distance_threshold
  mpar%compression_rate = gpar%compression_rate

  ! INVERSION parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, ipar%ninversions
  if (myrank == 0) print *, junk, ipar%ninversions

  read(10,2) junk, ipar%niter
  if (myrank == 0) print *, junk, ipar%niter

  read(10,1) junk, ipar%rmin
  if (myrank == 0) print *, junk, ipar%rmin

  read(10,2) junk, ipar%method
  if (myrank == 0) print *, junk, ipar%method

  read(10,1) junk, ipar%gamma
  if (myrank == 0) print *, junk, ipar%gamma

  ! MODEL DAMPING (m - m_prior) -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, ipar%alpha(1)
  if (myrank == 0) print *, junk, ipar%alpha(1)

  read(10,1) junk, ipar%alpha(2)
  if (myrank == 0) print *, junk, ipar%alpha(2)

  read(10,1) junk, ipar%norm_power
  if (myrank == 0) print *, junk, ipar%norm_power

  ! JOINT INVERSION parameters -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, ipar%problem_weight(1)
  if (myrank == 0) print *, junk, ipar%problem_weight(1)

  read(10,1) junk, ipar%problem_weight(2)
  if (myrank == 0) print *, junk, ipar%problem_weight(2)

  read(10,1) junk, ipar%column_weight_multiplier(1)
  if (myrank == 0) print *, junk, ipar%column_weight_multiplier(1)

  read(10,1) junk, ipar%column_weight_multiplier(2)
  if (myrank == 0) print *, junk, ipar%column_weight_multiplier(2)

  read(10,2) junk, tmparr(1)
  if (myrank == 0) print *, junk, tmparr(1)

  read(10,2) junk, tmparr(2)
  if (myrank == 0) print *, junk, tmparr(2)

  call ipar%set_niter_single(tmparr)

  ! Damping-gradient constraints -------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, ipar%damp_grad_weight_type
  if (myrank == 0) print *, junk, ipar%damp_grad_weight_type

  read(10,1) junk, ipar%beta(1)
  if (myrank == 0) print *, junk, ipar%beta(1)

  read(10,1) junk, ipar%beta(2)
  if (myrank == 0) print *, junk, ipar%beta(2)

  ! Cross-gradient constraints ---------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, ipar%cross_grad_weight
  if (myrank == 0) print *, junk, ipar%cross_grad_weight

  read(10,2) junk, ipar%method_of_weights_niter
  if (myrank == 0) print *, junk, ipar%method_of_weights_niter

  read(10,2) junk, ipar%derivative_type
  if (myrank == 0) print *, junk, ipar%derivative_type

  ! Clustering constraints -------------------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,1) junk, ipar%clustering_weight_glob(1)
  if (myrank == 0) print *, junk, ipar%clustering_weight_glob(1)

  read(10,1) junk, ipar%clustering_weight_glob(2)
  if (myrank == 0) print *, junk, ipar%clustering_weight_glob(2)

  read(10,2) junk, ipar%nclusters
  if (myrank == 0) print *, junk, ipar%nclusters

  read(10,3) junk, ipar%mixture_file
  if (myrank == 0) print *, junk, trim(ipar%mixture_file)

  read(10,3) junk, ipar%cell_weights_file
  if (myrank == 0) print *, junk, trim(ipar%cell_weights_file)

  read(10,2) junk, ipar%clustering_opt_type
  if (myrank == 0) print *, junk, ipar%clustering_opt_type

  read(10,2) junk, ipar%clustering_constraints_type
  if (myrank == 0) print *, junk, ipar%clustering_constraints_type

  ! ADMM constraints ------------------------------------------------

  read(10,'(a)') dum
  if (myrank == 0) print *, trim(dum)

  read(10,2) junk, ipar%admm_type
  if (myrank == 0) print *, junk, ipar%admm_type
  
  read(10,2) junk, ipar%nlithos
  if (myrank == 0) print *, junk, ipar%nlithos

  read(10,3) junk, ipar%bounds_ADMM_file(1)
  if (myrank == 0) print *, junk, trim(ipar%bounds_ADMM_file(1))
  
  read(10,3) junk, ipar%bounds_ADMM_file(2)
  if (myrank == 0) print *, junk, trim(ipar%bounds_ADMM_file(2))

  read(10,'(a)', advance='NO') junk
  read(10,*) ipar%rho_ADMM(1)
  if (myrank == 0) print *, junk, ipar%rho_ADMM(1)

  read(10,'(a)', advance='NO') junk
  read(10,*) ipar%rho_ADMM(2)
  if (myrank == 0) print *, junk, ipar%rho_ADMM(2)

  close(10)

  if (myrank == 0) print *, '**********************************************'

  ! Print out if we do this in double or single precision.
  if (myrank == 0) then
    if (CUSTOM_REAL == SIZE_DOUBLE) then
      print *, "precision                    = DOUBLE"
    else
      print *, "precision                    = SINGLE"
    endif
  endif

! Format to read a floating-point value.
 1 format(a, f16.8)

! Format to read an integer value.
 2 format(a, i8)

! Format to read a string.
 3 format(a, a)

end subroutine read_parfile

end module init_parameters