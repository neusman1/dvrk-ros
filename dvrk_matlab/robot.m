classdef robot < handle
    % Class used to interface with ROS topics and convert to useful
    % Matlab commands and properties.  To use:
    %   r = robot('PSM1);
    %   r.home();
    %   r.position_cartesian_desired   % contains 4x4 homogeneous transform

    % settings that are not supposed to change after constructor
    properties (SetAccess = immutable)
        ros_namespace % namespace for this arm, should contain head/tail / (default is /dvrk/)
        robot_name    % name of robot, e.g. PSM1, ECM.  Must match ROS topics namespace
        ros_name      % full ROS namespace, i.e. ros_name + robot_name (e.g. /dvrk/MTML)
    end

    % values set by this class, can be read by others
    properties (SetAccess = protected)
        robot_state                 % Internal robot state, string corresponding to C++ state
        robot_state_timer           % Timer used to wait for new robot states
        goal_reached                % Event to indicate if trajectory goal is reached
        goal_reached_timer          % Timer to block on trajectory

        position_cartesian_desired  % Last know desired cartesian position
        position_joint_desired      % Last know desired joint position
        position_cartesian_current  % Last know current cartesian position
        position_joint_current      % Last know current joint position
    end

    % only this class methods can view/modify
    properties (SetAccess = private)
        robot_state_subscriber
        robot_state_publisher
        goal_reached_subscriber
        position_cartesian_desired_subscriber
        position_joint_desired_subscriber
        position_cartesian_current_subscriber
        position_joint_current_subscriber
        position_goal_joint_publisher
    end

    methods

        function self = robot(name, namespace)
            % Create a robot interface.  The name must match the arm name
            % in ROS topics (test using rostopic list).  The namespace is
            % optional, default is /dvrk/.  It is provide for
            % configurations with multiple dVRK so one could have
            % /dvrkA/PSM1 and /dvrkB/PSM1
            if nargin == 1
                namespace = '/dvrk/';
            end
            self.ros_namespace = namespace;
            self.robot_name = name;
            self.ros_name = strcat(self.ros_namespace, self.robot_name);

            % ----------- subscribers
            % state
            topic = strcat(self.ros_name, '/robot_state');
            self.robot_state_subscriber = ...
                rossubscriber(topic, rostype.std_msgs_String);
            self.robot_state_subscriber.NewMessageFcn = ...
                @(sub, data)self.robot_state_callback(sub, data);
            % timer for robot state event
            self.robot_state_timer = timer('ExecutionMode', 'singleShot', ...
                                           'Name', strcat(self.ros_name, '_robot_state'), ...
                                           'ObjectVisibility', 'off');
            self.robot_state_timer.TimerFcn = { @self.robot_state_timout };

            % goal reached
            topic = strcat(self.ros_name, '/goal_reached');
            self.goal_reached_subscriber = ...
                rossubscriber(topic, rostype.std_msgs_Bool);
            self.goal_reached_subscriber.NewMessageFcn = ...
                @(sub, data)self.goal_reached_callback(sub, data);
            % timer for goal reached event
            self.goal_reached_timer = timer('ExecutionMode', 'singleShot', ...
                                           'Name', strcat(self.ros_name, '_goal_reached'), ...
                                           'ObjectVisibility', 'off', ...
                                           'StartDelay', 5.0); % 5s to complete trajectory

            self.goal_reached_timer.TimerFcn = { @self.goal_reached_timout };

            % position cartesian desired
            self.position_cartesian_desired = [];
            topic = strcat(self.ros_name, '/position_cartesian_desired');
            self.position_cartesian_desired_subscriber = ...
                rossubscriber(topic, rostype.geometry_msgs_Pose);
            self.position_cartesian_desired_subscriber.NewMessageFcn = ...
                @(sub, data)self.position_cartesian_desired_callback(sub, data);

            % position joint desired
            self.position_joint_desired = [];
            topic = strcat(self.ros_name, '/position_joint_desired');
            self.position_joint_desired_subscriber = ...
                rossubscriber(topic, rostype.sensor_msgs_JointState);
            self.position_joint_desired_subscriber.NewMessageFcn = ...
                @(sub, data)self.position_joint_desired_callback(sub, data);

            % position cartesian current
            self.position_cartesian_current = [];
            topic = strcat(self.ros_name, '/position_cartesian_current');
            self.position_cartesian_current_subscriber = ...
                rossubscriber(topic, rostype.geometry_msgs_Pose);
            self.position_cartesian_current_subscriber.NewMessageFcn = ...
                @(sub, data)self.position_cartesian_current_callback(sub, data);

            % position joint current
            self.position_joint_current = [];
            topic = strcat(self.ros_name, '/position_joint_current');
            self.position_joint_current_subscriber = ...
                rossubscriber(topic, rostype.sensor_msgs_JointState);
            self.position_joint_current_subscriber.NewMessageFcn = ...
                @(sub, data)self.position_joint_current_callback(sub, data);

            % ----------- publishers
            % state
            topic = strcat(self.ros_name, '/set_robot_state');
            self.robot_state_publisher = rospublisher(topic, rostype.std_msgs_String);

            % position goal joint
            topic = strcat(self.ros_name, '/set_position_goal_joint');
            self.position_goal_joint_publisher = rospublisher(topic, rostype.sensor_msgs_JointState);
        end

        function delete(self)
            % delete all timers
            delete(self.robot_state_timer);
            delete(self.goal_reached_timer);

            % hack to disable callbacks from subscribers
            % there might be a better way to remove the subscriber itself
            self.robot_state_subscriber.NewMessageFcn = @(a, b, c)[];
            self.goal_reached_subscriber.NewMessageFcn = @(a, b, c)[];
            self.position_cartesian_desired_subscriber.NewMessageFcn = @(a, b, c)[];
            self.position_joint_desired_subscriber.NewMessageFcn = @(a, b, c)[];
            self.position_cartesian_current_subscriber.NewMessageFcn = @(a, b, c)[];
            self.position_joint_current_subscriber.NewMessageFcn = @(a, b, c)[];
        end

        function robot_state_callback(self, ~, data) % second argument is subscriber, not used
            % Method used internally when a new robot_state is published by
            % the controller.  We use a timer to synchronize the callback
            % and user code.
            self.robot_state = data.Data;
            stop(self.robot_state_timer);
        end

        function robot_state_timout(self, ~, ~) % second parameter is timer, third is this function
            disp(strcat(self.robot_name, ': timeout robot state, current state is "', self.robot_state, '"'));
        end

        function goal_reached_callback(self, ~, data) % second argument is subscriber, not used
            % Method used internally when a new goal_reached is published by
            % the controller.  We use a timer to synchronize the callback
            % and user code.
            self.goal_reached = data.Data;
            stop(self.goal_reached_timer);
        end

        function goal_reached_timout(self, ~, ~) % second parameter is timer, third is this function
            disp(strcat(self.robot_name, ': timeout robot state, current state is "', self.goal_reached, '"'));
        end

        function position_cartesian_desired_callback(self, ~, pose) % second argument is subscriber, not used
            % Callback used to retrieve the last desired cartesian position
            % published and store as property position_cartesian_desired

            % convert idiotic ROS message type to homogeneous transforms
            position = trvec2tform([pose.Position.X, pose.Position.Y, pose.Position.Z]);
            orientation = quat2tform([pose.Orientation.W, pose.Orientation.X, pose.Orientation.Y, pose.Orientation.Z]);
            % combine position and orientation
            self.position_cartesian_desired = position * orientation;
        end

        function position_joint_desired_callback(self, ~, jointState) % second argument is subscriber, not used
            % Callback used to retrieve the last desired joint position published
            % and store as property position_joint_desired
            self.position_joint_desired = jointState.Position;
        end

        function position_cartesian_current_callback(self, ~, pose) % second argument is subscriber, not used
            % Callback used to retrieve the last measured cartesian position
            % published and store as property position_cartesian_current

            % convert idiotic ROS message type to homogeneous transforms
            position = trvec2tform([pose.Position.X, pose.Position.Y, pose.Position.Z]);
            orientation = quat2tform([pose.Orientation.W, pose.Orientation.X, pose.Orientation.Y, pose.Orientation.Z]);
            % combine position and orientation
            self.position_cartesian_current = position * orientation;
        end

        function position_joint_current_callback(self, ~, jointState) % second argument is subscriber, not used
            % Callback used to retrieve the last measured joint position published
            % and store as property position_joint_current
            self.position_joint_current = jointState.Position;
        end

        function result = set_state(self, state_as_string)
            % Set the robot state.  For homing, used the robot.home()
            % method instead.  This is used internally to switch between
            % the joint/cartesian and direct/trajectory modes
            message = rosmessage(self.robot_state_publisher);
            message.Data = state_as_string;
            self.robot_state_timer.StartDel = 5.0; % 5 seconds should be plenty for most state changes
            start(self.robot_state_timer);
            send(self.robot_state_publisher, message);
            wait(self.robot_state_timer);
            result = strcmp(self.robot_state, state_as_string);
            if not(result)
                disp(strcat(self.robot_name, ...
                            ': failed to reach state "', ...
                            state_as_string, ...
                            '", current state is "', ...
                            self.robot_state, ...
                            '"'));
            end
        end

        function home(self)
            % Home the robot.  This method will request power on, calibrate
            % and then go to home position.   For a PSM, this method will
            % wait for the state DVRK_READY.  This state can only be
            % reached if the user inserts the sterile adapter and the tool
            message = rosmessage(self.robot_state_publisher);
            message.Data = 'Home';
            send(self.robot_state_publisher, message);
            counter = 21; % up to 20 * 3 seconds transitions to get ready
            self.robot_state_timer.StartDelay = 3.0;
            done = false;
            while not(done)
                start(self.robot_state_timer);
                wait(self.robot_state_timer);
                counter = counter - 1;
                homed = strcmp(self.robot_state, 'DVRK_READY');
                done = (counter == 0) | homed;
                if (not(done))
                    disp(strcat(self.robot_name, ...
                                ': waiting for state DVRK_READY, ', ...
                                int2str(counter)))
                end
            end
            if not(homed)
                disp(strcat(self.robot_name, ...
                            ': failed to home, last state "', ...
                            self.robot_state, '"'))
            end
        end

        function result = joint_move(self, joint_values)
            % Move to absolute joint value using trajectory
            % generator

            % check if the array provided has the right length
            if length(joint_values) == length(self.position_joint_current)
                if self.set_state('DVRK_POSITION_GOAL_JOINT')
                    % prepare the ROS message
                    joint_message = rosmessage(self.position_goal_joint_publisher);
                    joint_message.Position = joint_values;
                    % reset goal reached value and timer
                    self.goal_reached = false;
                    start(self.goal_reached_timer);
                    % send message
                    send(self.position_goal_joint_publisher, ...
                         joint_message);
                    % wait for timer to be interrupted by goal_reached
                    wait(self.goal_reached_timer);
                    result = self.goal_reached;
                else
                    % unable to set the desired state
                    % set_state should already provide a message
                    result = false;
                end
            else
                result = false;
                disp(strcat(self.robot_state, ...
                            [': joint_move, joint_values does not have right ' ...
                             'size, size of provided array is '], ...
                            int2str(length(joint_values))));
            end
        end

        function result = delta_joint_move_single(self, joint_value, joint_index)
            % Move one single joint by increment, first argument is
            % value (radian or meter), second parameter in joint
            % index (from 1 for first joint)
            if self.set_state('DVRK_POSITION_GOAL_JOINT')
                joint_goal = self.position_joint_desired;
                joint_goal(joint_index) = joint_goal(joint_index) + joint_value;
                result = self.joint_move(joint_goal);
            else
                result = false
            end
        end

        function delta_joint_move_list(self, value, index)
            if isfloat(value) && isfloat(index) && length(value) == length(index)
                self.set_state('DVRK_POSITION_GOAL_JOINT');
                jointState = rosmessage(self.position_goal_joint_publisher);
                jointState.Position = self.position_joint_desired;
                for i = 1:length(value)
                    jointState.Position(index(i)) = jointState.Position(index(i)) + value(i);
                end
                send(self.position_goal_joint_publisher, jointState);
            else
                disp(strcat(self.robot_name, ...
                            ': delta_joint_move_list: ', ...
                            'parameters must be arrays of the same length'));
            end

        end

        function joint_move_single(self, value, index)
            self.set_state('DVRK_POSITION_GOAL_JOINT');
            jointState = rosmessage(self.position_goal_joint_publisher);
            jointState.Position = self.position_joint_desired;
            jointState.Position(index) = value;
            send(self.position_goal_joint_publisher, jointState);
        end

        function joint_move_list(self, value, index)
            if isfloat(value) && isfloat(index) && length(value) == length(index)
                self.set_state('DVRK_POSITION_GOAL_JOINT');
                jointState = rosmessage(self.position_goal_joint_publisher);
                jointState.Position = self.position_joint_desired;
                for i = 1:length(value)
                    jointState.Position(index(i)) = value(i);
                end
                send(self.position_goal_joint_publisher, jointState);
            end
        end
    end
end
