class Integrator:
    r"""
        Base integration class
    
    """
class Oscillate(Integrator):
    r"""
        Move particles with the periodically changing velocity
        :math:`\mathbf{u}(t) = \cos(2 \pi \, t / T) \mathbf{u}_0`
    
    """
    def __init__():
        r"""__init__(name: str, dt: float, velocity: Tuple[float, float, float], period: float) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    velocity: :math:`\mathbf{u}_0`
                    period: oscillation period :math:`T`
            

        """
        pass

class RigidVelocityVerlet(Integrator):
    r"""
        Integrate the position and rotation (in terms of quaternions) of the rigid bodies as per Velocity-Verlet scheme.
        Can only applied to :any:`RigidObjectVector` or :any:`RigidEllipsoidVector`.
    
    """
    def __init__():
        r"""__init__(name: str, dt: float) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
            

        """
        pass

class Rotate(Integrator):
    r"""
        Rotate particles around the specified point in space with a constant angular velocity :math:`\mathbf{\Omega}`
    
    """
    def __init__():
        r"""__init__(name: str, dt: float, center: Tuple[float, float, float], omega: Tuple[float, float, float]) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    center: point around which to rotate
                    omega: angular velocity :math:`\mathbf{\Omega}`
            

        """
        pass

class SubStepMembrane(Integrator):
    r"""
            Takes advantage of separation of time scales between membrane forces (fast forces) and other forces acting on the membrane (slow forces).
            This integrator advances the membrane with constant slow forces for 'substeps' sub time steps.
            The fast forces are updated after each sub step.
            Positions and velocity are updated using an internal velocity verlet integrator.
        
    """
    def __init__():
        r"""__init__(name: str, dt: float, substeps: int, fastForces: Interactions.Interaction) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    substeps: number of sub steps
                    fastForces: the fast interaction module. Only accepts `InteractionMembrane`!
            

        """
        pass

class Translate(Integrator):
    r"""
        Translate particles with a constant velocity :math:`\mathbf{u}` regardless forces acting on them.
    
    """
    def __init__():
        r"""__init__(name: str, dt: float, velocity: Tuple[float, float, float]) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    velocity: translational velocity :math:`\mathbf{\Omega}`
            

        """
        pass

class VelocityVerlet(Integrator):
    r"""
            Classical Velocity-Verlet integrator with fused steps for coordinates and velocities.
            The velocities are shifted with respect to the coordinates by one half of the time-step
            
            .. math::

                \mathbf{a}^{n} &= \frac{1}{m} \mathbf{F}(\mathbf{x}^{n}, \mathbf{v}^{n-1/2}) \\
                \mathbf{v}^{n+1/2} &= \mathbf{v}^{n-1/2} + \mathbf{a}^n \Delta t \\
                \mathbf{x}^{n+1} &= \mathbf{x}^{n} + \mathbf{v}^{n+1/2} \Delta t 

            where bold symbol means a vector, :math:`m` is a particle mass, and superscripts denote the time: :math:`\mathbf{x}^{k} = \mathbf{x}(k \, \Delta t)`
        
    """
    def __init__():
        r"""__init__(name: str, dt: float) -> None


                Args:
                    name: name of the integrator
                    dt:   integration time-step
            

        """
        pass

class VelocityVerlet_withConstForce(Integrator):
    r"""
            Same as regular :any:`VelocityVerlet`, but the forces on all the particles are modified with the constant pressure term:
   
            .. math::

                \mathbf{a}^{n} &= \frac{1}{m} \left( \mathbf{F}(\mathbf{x}^{n}, \mathbf{v}^{n-1/2}) + \mathbf{F}_{extra} \right) \\
        
    """
    def __init__():
        r"""__init__(name: str, dt: float, force: Tuple[float, float, float]) -> None



                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    force: :math:`\mathbf{F}_{extra}`
            

        """
        pass

class VelocityVerlet_withPeriodicForce(Integrator):
    r"""
            Same as regular Velocity-Verlet, but the forces on all the particles are modified with periodic Poiseuille term.
            This means that all the particles in half domain along certain axis (Ox, Oy or Oz) are pushed with force
            :math:`F_{Poiseuille}` parallel to Oy, Oz or Ox correspondingly, and the particles in another half of the domain are pushed in the same direction
            with force :math:`-F_{Poiseuille}`    
        
    """
    def __init__():
        r"""__init__(name: str, dt: float, force: float, direction: str) -> None

                
                Args:
                    name: name of the integrator
                    dt:   integration time-step
                    force: force magnitude, :math:`F_{Poiseuille}`
                    direction: Valid values: \"x\", \"y\", \"z\". Defines the direction of the pushing force
                               if direction is \"x\", the sign changes along \"y\".
                               if direction is \"y\", the sign changes along \"z\".
                               if direction is \"z\", the sign changes along \"x\".
            

        """
        pass


