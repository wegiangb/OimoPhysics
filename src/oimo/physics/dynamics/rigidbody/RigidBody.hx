package oimo.physics.dynamics.rigidbody;
import oimo.m.IMat3;
import oimo.m.IQuat;
import oimo.m.IVec3;
import oimo.m.M;
import oimo.math.MathUtil;
import oimo.physics.collision.shape.Shape;
import oimo.physics.collision.shape.Transform;
import oimo.physics.dynamics.rigidbody.Component;

/**
 * Rigid body.
 */
@:expose("OIMO.RigidBody")
@:build(oimo.m.B.bu())
class RigidBody {
	public var _next:RigidBody;
	public var _prev:RigidBody;

	public var _componentList:Component;
	public var _componentListLast:Component;

	public var _linearVel:IVec3;
	public var _angularVel:IVec3;

	public var _ptransform:Transform;
	public var _transform:Transform;

	public var _type:RigidBodyType;

	public var _sleeping:Bool;

	public var _invMass:Float;
	public var _invLocalInertia:IMat3;
	public var _invInertia:IMat3;

	public var _rotationFactor:IVec3;

	public var _world:World;

	public function new(config:RigidBodyConfig) {
		_next = null;
		_prev = null;

		_componentList = null;
		_componentListLast = null;

		M.vec3_fromVec3(_linearVel, config.linearVelocity);
		M.vec3_fromVec3(_angularVel, config.angularVelocity);

		_ptransform = new Transform();
		_transform = new Transform();
		M.vec3_fromVec3(_ptransform._origin, config.position);
		M.mat3_fromMat3(_ptransform._rotation, config.rotation);
		M.transform_assign(_transform, _ptransform);

		_type = config.type;

		_invMass = 0;
		M.mat3_zero(_invLocalInertia);
		M.mat3_zero(_invInertia);

		M.vec3_set(_rotationFactor, 1, 1, 1);

		_world = null;
	}

	inline function _updateMass():Void {
		var totalInertia:IMat3;
		var totalMass:Float;
		M.mat3_zero(totalInertia);
		totalMass = 0;

		var c:Component = _componentList;
		M.list_foreach(c, _next, {
			var s:Shape = c._shape;
			s._updateMass();

			var mass:Float = c._density * s._volume;
			var inertia:IMat3;

			// I_transformed = (R * I_localCoeff * R^T) * mass
			M.mat3_transformInertia(inertia, s._inertiaCoeff, c._localTransform._rotation);
			M.mat3_scale(inertia, inertia, mass);

			// I_cog = [ x*x, -x*y, -x*z;
			//          -x*y,  y*y, -x*z; * mass
			//          -x*z, -y*z,  z*z]
			// I = I_transformed + I_cog
			var cogInertia:IMat3;
			M.mat3_inertiaFromCOG(cogInertia, c._localTransform._origin);
			M.mat3_addRhsScaled(inertia, inertia, cogInertia, mass);

			// add mass data
			totalMass += mass;
			M.mat3_add(totalInertia, totalInertia, inertia);
		});

		if (totalMass > MathUtil.EPS && _type == Dynamic) {
			// set mass and inertia
			_invMass = 1 / totalMass;
			M.mat3_inv(_invLocalInertia, totalInertia);
			M.mat3_scaleRowsVec3(_invLocalInertia, _invLocalInertia, _rotationFactor);

			// set transformed inertia
			M.mat3_transformInertia(_invInertia, _invLocalInertia, _transform._rotation);
		} else {
			// set mass and inertia
			_invMass = 0;
			M.mat3_zero(_invLocalInertia);

			// set transformaed inertia
			M.mat3_zero(_invInertia);

			// force body type to be static or kinematic
			if (_type == Dynamic) {
				_type = Static;
			}
		}
	}

	@:extern
	public inline function _integrate(timeStep:Float):Void {
		M.transform_assign(_ptransform, _transform);
		switch (_type) {
		case Dynamic:
			var translation:IVec3;
			var rotation:IVec3;
			M.vec3_scale(translation, _linearVel, timeStep);
			M.vec3_scale(rotation, _angularVel, timeStep);

			var l:Float;
			// limit linear velocity
			l = M.vec3_dot(translation, translation);
			if (l > Settings.maxTranslationPerStepSq) {
				l = Settings.maxTranslationPerStep / MathUtil.sqrt(l);
				M.vec3_scale(_linearVel, _linearVel, l);
			}

			// limit angular velocity
			l = M.vec3_dot(rotation, rotation);
			if (l > Settings.maxRotationPerStepSq) {
				l = Settings.maxRotationPerStep / MathUtil.sqrt(l);
				M.vec3_scale(_angularVel, _angularVel, l);
			}

			// integrate position
			M.vec3_addRhsScaled(_transform._origin, _transform._origin, _linearVel, timeStep);

			// compute derivative of the quaternion
			var angVelLength:Float = M.vec3_length(_angularVel);
			var halfAng:Float = angVelLength * timeStep * 0.5;
			var angVelToAxisFactor:Float; // sin(halfAngle) / angVelLength;
			var cosHalfAng:Float;         // cos(halfAngle)
			if (halfAng < 0.5) { // use Maclaurin expansion

				// [Accuracy data]
				//     --------------------------------------------------------
				//      halfAng = 0.5, timeStep = 1 / 60, using 64-bit floats
				//     --------------------------------------------------------
				//      angVelToAxisFactor:
				//          exact value   | 0.007990425643403383
				//          approximation | 0.007990425553902118
				//          error         | 8.950126577367268E-11
				//     --------------------------------------------------------
				//      cosHalfAng:
				//          exact value   | 0.8775825618903728
				//          approximation | 0.8775824652777777
				//          error         | 9.661259503523922E-8
				//     --------------------------------------------------------

				var ha2:Float = halfAng * halfAng;
				angVelToAxisFactor = timeStep * 0.5 * (1 - ha2 * (1 / 6) + ha2 * ha2 * (1 / 120));
				cosHalfAng = 1 - ha2 * (1 / 2) + ha2 * ha2 * (1 / 24);
			} else {
				angVelToAxisFactor = MathUtil.sin(halfAng) / angVelLength;
				cosHalfAng = MathUtil.cos(halfAng);
			}
			var sinAxis:IVec3;
			M.vec3_scale(sinAxis, _angularVel, angVelToAxisFactor);
			var dq:IQuat;
			M.quat_fromVec3AndFloat(dq, sinAxis, cosHalfAng);

			// integrate quaternion
			var q:IQuat;
			M.quat_fromMat3(q, _transform._rotation);
			M.quat_mul(q, dq, q);
			M.quat_normalize(q, q);

			// update rotation
			M.mat3_fromQuat(_transform._rotation, q);

		case Static, Kinematic:
			M.vec3_zero(_linearVel);
			M.vec3_zero(_angularVel);
		}
	}

	@:extern
	public inline function _syncComponents():Void {
		var c:Component = _componentList;
		M.list_foreach(c, _next, {
			M.call(c._sync(_ptransform, _transform));
		});
	}

	// --- public ---

	public function addComponent(component:Component):Void {
		// first, add the component to the linked list so that it will be considered
		M.list_push(_componentList, _componentListLast, _prev, _next, component);
		component._rigidBody = this;

		// then add the component to the world
		if (_world != null) {
			_world._addComponent(component);
		}

		// finally, update mass data and synchronize the components
		_updateMass();
		_syncComponents();
	}

	public function removeComponent(component:Component):Void {
		// first, remove the component from the linked list so that it will be ignored
		M.list_remove(_componentList, _componentListLast, _prev, _next, component);
		component._rigidBody = null;

		// then remove the component from the world
		if (_world != null) {
			_world._removeComponent(component);
		}

		// finally, update mass data and synchronize the components
		_updateMass();
		_syncComponents();
	}

	public function setType(type:RigidBodyType):Void {
		_type = type;
		_updateMass();
	}

	/**
	 * The next rigid body in the world.
	 */
	public var next(get, null):RigidBody;

	inline function get_next():RigidBody {
		return _next;
	}

}
